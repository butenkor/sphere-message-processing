Rx = require 'rx'
Q = require 'q'
{_} = require 'underscore'
{Rest} = require 'sphere-node-connect'
{TaskQueue} = require '../lib/task_queue'
{Pagger} = require '../lib/pagger'
{Repeater} = require '../lib/repeater'
util = require '../lib/util'
cache = require 'lru-cache'

class SphereService
  @create: (stats, options) ->
    (new SphereService(stats, options))._init()

  constructor: (@stats, options) ->
    @accessTokenExpirationBeforeRenewalMs = options.accessTokenExpirationBeforeRenewalMs or (2 * 60 * 60 * 1000) # 2h
    @sphereHost = options.sphereHost
    @fetchHours = options.fetchHours
    @statsPrefix = options.statsPrefix or ""
    @messagesPageSize = options.messagesPageSize
    @requestQueue = options.requestQueue or (new TaskQueue @stats, {maxParallelTasks: 100})
    @additionalMessageCriteria = options.additionalMessageCriteria
    @additionalMessageExpand = options.additionalMessageExpand or []
    @processorName = options.processorName
    @projectKey = options.connector.config.project_key
    @projectProps = options.connector.config.props

    @_messageFetchInProgress = false
    @_client = new Rest _.extend({}, {host: @sphereHost}, options.connector)

    @referenceCacheOptions = options.referenceCacheOptions or {max: 1000, maxAge: 60 * 60 * 1000}
    @referenceCache = cache @referenceCacheOptions

    @requestMeter = @stats.addCustomMeter @statsPrefix + @projectKey, "requests"
    @requestTimer = @stats.addCustomTimer @statsPrefix + @projectKey, "requestTime"

    @stats.addCustomStat @statsPrefix + @projectKey, "referenceCacheSize", =>
      _.size @referenceCache

    @stats.cacheClearCommands.subscribe =>
      @referenceCache.reset()

  _init: () ->
    @_renewAccessToken()
    .then =>
      @_startAccessTokenRenewalTask()
      this

  _startAccessTokenRenewalTask: () ->
    Rx.Observable.interval(10 * 60 * 1000)
    .subscribe =>
      if @_getRemainingAccessTokenTimeMs() < @accessTokenExpirationBeforeRenewalMs
        @_renewAccessToken()
        .then ->
          console.error "Sccess token renewed #{new Date}"
        .fail (error) ->
          console.error "Failed to renew access token!! #{new Date()}"
          console.error error.stack
        .done()

  _getRemainingAccessTokenTimeMs: () ->
    (@_accessToken.gotAt.getTime() + (@_accessToken.expires_in * 1000)) - Date.now()

  _renewAccessToken: () ->
    new Repeater {attempts: 10}
    .execute
      recoverableError: (e) ->
        console.error "Failed to get access token. Retrying...", e.message
        true
      task: =>
        @_getOAuthToken()
        .then (token) =>
          @_accessToken = token
          @_accessToken.gotAt = new Date()

          # Not nice, but should work for the moment being
          @_client._options.access_token = token.access_token
          @_client._options.headers['Authorization'] = "Bearer #{token.access_token}"

  _getOAuthToken: () ->
    d = Q.defer()

    @requestMeter.mark()
    stopwatch = @requestTimer.start()
    @_client._oauth.getAccessToken (error, response, body) =>
      stopwatch.end()

      if error
        d.reject error
      else if response.statusCode is 200 or response.statusCode is 201
        d.resolve body
      else
        d.reject new ErrorStatusCode(response.statusCode, body)

    d.promise

  _get: (path) ->
    @requestQueue.addTask =>
      d = Q.defer()

      @requestMeter.mark()
      stopwatch = @requestTimer.start()
      @_client.GET path, (error, response, body) ->
        stopwatch.end()
        if error
          d.reject error
        else if response.statusCode is 200
          d.resolve body
        else
          d.reject new ErrorStatusCode(response.statusCode, body)

      d.promise

  _post: (path, json) ->
    @requestQueue.addTask =>
      d = Q.defer()

      @requestMeter.mark()
      stopwatch = @requestTimer.start()
      @_client.POST path, json, (error, response, body) ->
        stopwatch.end()
        if error
          d.reject error
        else if response.statusCode is 200 or response.statusCode is 201
          d.resolve body
        else
          d.reject new ErrorStatusCode(response.statusCode, body)

      d.promise

  _delete: (path) ->
    @requestQueue.addTask =>
      d = Q.defer()

      @requestMeter.mark()
      stopwatch = @requestTimer.start()
      @_client.DELETE path, (error, response, body) ->
        stopwatch.end()
        if error
          d.reject error
        else if response.statusCode is 200
          d.resolve body
        else
          d.reject new ErrorStatusCode(response.statusCode, body)

      d.promise

  getSourceInfo: () ->
    {name: "sphere.#{@projectKey}", prefix: @projectKey, sphere: this}

  # TODO: (optimization) remember the last error date so that amount of the messages can be reduced
  getMessageSource: ->
    subject = new Rx.Subject()

    observable = subject
    .flatMap =>
      @_loadLatestMessages()

    [subject, observable]

  getRecentMessages: (fromDate, offset, limit) ->
    additional = if @additionalMessageCriteria? then " and #{@additionalMessageCriteria}" else ""

    @_get @_pathWhere("/messages", "createdAt > \"#{util.formatDate fromDate}\"#{additional}", ["createdAt asc"], ["resource"].concat(@additionalMessageExpand), limit, offset)

  _loadLatestMessages: () ->
    if @_messageFetchInProgress
      # if it takes too much time to get messages, then just ignore
      Rx.Observable.fromArray []
    else
      @_messageFetchInProgress = true
      limitDate = util.addDateTime(new Date(), -1 * @fetchHours, 0, 0)

      new Pagger
        pageSize: @messagesPageSize
        onNextPage: (offset, limit) =>
          @getRecentMessages limitDate, offset, limit
        onError: (error) =>
          console.error "Error during message fetch!"
          console.error error.stack
          @stats.reportMessageFetchError()
        onFinish: =>
          @_messageFetchInProgress = false
        applyBackpressureOnNextPage: (offset, limit, total)=>
          @stats.applyBackpressureAtNextMessagePage offset, limit, total
      .page()

  getLastProcessedSequenceNumber: (resource) ->
    @_get "/custom-objects/#{@processorName}.lastSequenceNumber/#{resource.typeId}-#{resource.id}"
    .then (resp) ->
      resp.value
    .fail (error) ->
      if error instanceof ErrorStatusCode and (error.code is 404)
        0
      else
        throw error

  reportSuccessfullProcessing: (msg, lock, result) ->
    lastSnJson =
      container: "#{@processorName}.lastSequenceNumber"
      key: "#{msg.resource.typeId}-#{msg.resource.id}"
      value: msg.sequenceNumber

    @_post "/custom-objects", lastSnJson
    .then =>
      lock.value.state = "processed"
      lock.value.result = result if result?

      @_post "/custom-objects", lock

  reportMessageProcessingFailure: (msg, lock, error, processor) ->
    Q("updateLatSequenceNumber")
    .then =>
      lock.value.state = "error"
      lock.value.stage = processor
      lock.value.error = error.stack

      @_post "/custom-objects", lock

  _tryTakeLock: (id) ->
    json =
      container: "#{@processorName}.messages"
      key: "#{id}"
      version: 0
      value:
        state: "lockedForProcessing"

    @_post "/custom-objects", json
    .then (lock) ->
      {type: "new", payload: lock}
    .fail (error) =>
      if error instanceof ErrorStatusCode and (error.code is 409 or error.code is 500) # 500 because of the missing improvement
        # was just created by comeone
        @_get "/custom-objects/#{@processorName}.messages/#{id}"
        .then (lock) ->
          {type: "existing", payload: lock}
      else
        throw error

  _findMessageProcessingRecordOrLock: (id) ->
    @_get "/custom-objects/#{@processorName}.messages/#{id}"
    .then (lock) ->
      {type: "existing", payload: lock}
    .fail (error) =>
      if error instanceof ErrorStatusCode and error.code is 404
        @_tryTakeLock id
      else
        throw error

  lockMessage: (msg) ->
    @_findMessageProcessingRecordOrLock msg.id

  unlockMessage: (msg, lock) ->
    @_delete "/custom-objects/#{@processorName}.messages/#{msg.id}?version=#{lock.version}"

  _pathWhere: (path, where, sort = [], expand = [], limit = 100, offset = 0) ->
    sorting = if not _.isEmpty(sort) then "&" + _.map(sort, (s) -> "sort=" + encodeURIComponent(s)).join("&") else ""
    expanding = if not _.isEmpty(sort) then "&" + _.map(expand, (e) -> "expand=" + encodeURIComponent(e)).join("&") else ""

    "#{path}?where=#{encodeURIComponent(where)}#{sorting}#{expanding}&limit=#{limit}&offset=#{offset}"

  ensureChannels: (defs) ->
    promises = _.map defs, (def) =>
      @_get @_pathWhere('/channels', "key=\"#{def.key}\"")
      .then (list) =>
        if list.total is 0
          json =
            key: def.key
            roles: def.roles
          @_post "/channels", json
        else
          list.results[0]
      .then (channel) ->
        channel.definition = def
        channel

    Q.all promises

  ensureTaxCategories: (defs) ->
    promises = _.map defs, (def) =>
      @_get @_pathWhere('/tax-categories', "name=\"#{def.name}\"")
      .then (list) =>
        if list.total is 0
          @_post "/tax-categories", def
        else
          list.results[0]
      .then (tc) ->
        tc.definition = def
        tc

    Q.all promises

  ensureStates: (defs) ->
    statePromises = _.map defs, (def) =>
      @_get @_pathWhere('/states', "key=\"#{def.key}\" and type=\"LineItemState\"")
      .then (list) =>
        if list.total is 0
          json =
            key: def.key
            type: 'LineItemState'
            initial: false
          @_post "/states", json
        else
          list.results[0]
      .then (state) ->
        state.definition = def
        state

    Q.all statePromises
    .then (createdStates) =>
      finalPromises = _.map createdStates, (state) =>
        if (not state.transitions? and state.definition.transitions?) or (state.transitions? and not state.definition.transitions?) or (state.transitions? and state.definition.transitions? and _.size(state.transitions) != _.size(state.definition.transitions))
          json =
            if state.definition.transitions?
              version: state.version
              actions: [{action: 'setTransitions', transitions: _.map(state.definition.transitions, (tk) -> {typeId: 'state', id: _.find(createdStates, (s) -> s.key is tk).id})}]
            else
              version: state.version
              actions: [{action: 'setTransitions'}]

          @_post "/states/#{state.id}", json
        else
          Q(state)

      Q.all finalPromises

  getFirstProduct: () ->
    @_get "/products?limit=1"
    .then (res) ->
      if res.total is 0
        throw new Error("No products in the project")
      else
        res.results[0]

  importOrder: (json) ->
    @_post "/orders/import", json

  updateOrderSyncSuatus: (order, channel, externalId) ->
    json =
      version: order.version
      actions: [{action: 'updateSyncInfo', channel: {typeId: "channel", id: channel.id}, externalId: externalId}]

    @_post "/orders/#{order.id}", json

  transitionLineItemState: (order, lineItemId, quantity, fromState, toState, date) ->
    @transitionLineItemStates order, lineItemId, [
      {quantity: quantity, fromState: fromState, toState: toState, date: date}
    ]

  transitionCustomLineItemState: (order, lineItemId, quantity, fromState, toState, date) ->
    @transitionCustomLineItemStates order, lineItemId, [
      {quantity: quantity, fromState: fromState, toState: toState, date: date}
    ]

  # transition json: quantity, fromState, toState, date
  transitionLineItemStates: (order, lineItemId, transitions) ->
    actions = _.map transitions, (t) ->
      action =
        action: 'transitionLineItemState'
        lineItemId: lineItemId
        quantity: t.quantity
        fromState: t.fromState
        toState: t.toState

      if t.date?
        action.actualTransitionDate = t.date

      action

    json =
      version: order.version
      actions: actions

    @_post "/orders/#{order.id}", json

  transitionCustomLineItemStates: (order, lineItemId, transitions) ->
    actions = _.map transitions, (t) ->
      action =
        action: 'transitionCustomLineItemState'
        customLineItemId: lineItemId
        quantity: t.quantity
        fromState: t.fromState
        toState: t.toState

      if t.date?
        action.actualTransitionDate = t.date

      action

    json =
      version: order.version
      actions: actions

    @_post "/orders/#{order.id}", json

  addDelivery: (order, deliveryItems) ->
    action =
      action: 'addDelivery'
      items: deliveryItems

    json =
      version: order.version
      actions: [action]

    @_post "/orders/#{order.id}", json

  addParcel: (order, deliveryId, measurements, trackingData) ->
    action =
      action: 'addParcelToDelivery'
      deliveryId: deliveryId

    action.measurements = measurements if measurements?
    action.trackingData = trackingData if trackingData?

    json =
      version: order.version
      actions: [action]

    @_post "/orders/#{order.id}", json

  _refCacheKey: (ref) ->
    ref.typeId + "-" + ref.id

  _keyCacheKey: (type, key) ->
    'keys' + '-' + type + '-' + key

  getChannelByRef: (ref) ->
    @_getCachedRef ref, (id) =>
      @_get "/channels/#{id}"

  getChannelByKey: (key) ->
    @_getCachedKey 'channel', key, (key) =>
      @_get @_pathWhere("/channels", "key=\"#{key}\"")
      .then (res) ->
        if res.total is not 1
          throw new Error("Channel with key: #{key} not found!")
        else
          res.results[0]

  getStateByKey: (key, type) ->
    @_getCachedKey 'state', type + '.' + key, (k) =>
      @_get @_pathWhere("/states", "key=\"#{key}\" and type=\"#{type}\"")
      .then (res) ->
        if res.total is not 1
          throw new Error("State with key #{key} of type #{type} not found!")
        else
          res.results[0]

  getStateByRef: (ref) ->
    @_getCachedRef ref, (id) =>
      @_get "/states/#{id}"

  _getCachedKey: (type, key, fetchFn) ->
    cached = @referenceCache.get @_keyCacheKey(type, key)

    if cached?
      Q(cached)
    else
      fetchFn(key)
      .then (res) =>
        @referenceCache.set @_keyCacheKey(type, key), res
        res

  _getCachedRef: (ref, fetchFn) ->
    cached = @referenceCache.get @_refCacheKey(ref)

    if ref.obj?
      @referenceCache.set @_refCacheKey(ref), ref.obj
      Q(ref.obj)
    else if cached?
      Q(cached)
    else
      fetchFn(ref.id)
      .then (res) =>
        @referenceCache.set @_refCacheKey(ref), res
        res

  getOrderById: (id) ->
    @_get "/orders/#{id}"

  getInvetoryEntryBySkuAndChannel: (sku, channelRef) ->
    skuQuery = "sku=\"#{sku}\""
    channelQuery =
      if channelRef?
        "supplyChannel(id=\"#{channelRef.id}\")"
      else
        "supplyChannel is not defined"

    query = "#{skuQuery} and #{channelQuery}"

    @_get @_pathWhere("/inventory", query)
    .then (results) ->
      if results.total == 0
        Q.reject new Error("Can't find inventory by SKU '#{sku}' and channel '#{if channelRef? then channelRef.id else 'none'}'.")
      else if results.total > 1
        Q.reject new Error("More than one inventory found for for the query: '#{query}'.")
      else
        results.results[0]

  removeInventoryQuantity: (inventoryEntry, quantity) ->
    json =
      version: inventoryEntry.version
      actions: [{action: 'removeQuantity', quantity: quantity}]

    @_post "/inventory/#{inventoryEntry.id}", json

  addInventoryQuantity: (inventoryEntry, quantity) ->
    json =
      version: inventoryEntry.version
      actions: [{action: 'addQuantity', quantity: quantity}]

    @_post "/inventory/#{inventoryEntry.id}", json

  createInventoryEntry: (sku, quantity) ->
    json =
      sku: sku
      quantityOnStock: quantity

    @_post "/inventory", json


class ErrorStatusCode extends Error
  constructor: (@code, @body) ->
    @message = "Status code is #{@code}: #{JSON.stringify @body}"
    @name = 'ErrorStatusCode'
    Error.captureStackTrace this, this

exports.SphereService = SphereService
exports.ErrorStatusCode = ErrorStatusCode