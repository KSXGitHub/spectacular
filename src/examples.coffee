
## Expectation

class spectacular.Expectation
  constructor: (@example,
                @actual,
                matcher,
                @not=false,
                @callstack,
                ownDescription) ->
    @matcher = Object.create matcher
    @ownDescription = if ownDescription?
      "#{ownDescription} "
    else
      ''

  match: =>
    promise = new spectacular.Promise
    timeout = null
    spectacular.Promise.unit()
    .then =>
      timeout = setTimeout =>
        @success = false
        @trace = new Error 'matcher timed out'
        if @not
          @message = @matcher.messageForShouldnt
        else
          @message = @matcher.messageForShould
        @description = "should#{if @not then ' not' else ''} #{@matcher.description}"
        promise.resolve @success
      , @matcher.timeout or 5000

      @matcher.match(@actual)
    .then (@success) =>
      clearTimeout timeout
      @success = not @success if @not
      @createMessage()
      promise.resolve @success
    .fail (@trace) =>
      clearTimeout timeout
      @success = false
      @matcher.message = @trace.message unless @matcher.message?
      @matcher.description = '' unless @matcher.description?
      promise.reject @trace

    promise

  createMessage: =>
    if @not
      @message = @matcher.messageForShouldnt
    else
      @message = @matcher.messageForShould
    if not @success and not @trace?
      if @callstack.stack?
        stack = @callstack.stack.split('\n')
        specIndex = spectacular.env.runner.findSpecFileInStack stack
        @callstack.stack = stack[specIndex..].join('\n') if specIndex isnt -1
      @trace = @callstack

    @description = "#{@ownDescription}should#{if @not then ' not' else ''} #{@matcher.description}"
    @fullDescription = "#{@example.description} #{@ownDescription}should#{if @not then ' not' else ''} #{@matcher.description}"

## ExampleResult

class spectacular.ExampleResult
  @include spectacular.HasCollection('expectations', 'expectation')

  constructor: (@example, @state) ->
    @expectations = []
    @promise = spectacular.Promise.unit()

  hasFailures: -> @expectations.some (e) -> not e.success

  _addExpectation = ExampleResult::addExpectation
  addExpectation: (expectation) ->
    successHandler = => expectation.match().fail (e) =>
      @example.error e
    @promise = @promise.then successHandler
    _addExpectation.call this, expectation


## Example

class spectacular.Example
  @include spectacular.HasAncestors
  @include spectacular.Describable
  @extend spectacular.AncestorsProperties

  @followUp 'subjectBlock'
  @followUp 'cascading'
  @followUp 'inclusive'
  @followUp 'exclusive'

  @mergeUp 'beforeHooks'
  @mergeUp 'afterHooks'
  @mergeUp 'dependencies'

  constructor: (@block, @ownDescription='', @parent) ->
    @noSpaceBeforeDescription = true if @ownDescription is ''
    @beforeHooks = []
    @afterHooks = []
    @dependencies = []
    @cascading = null
    @inclusive = false
    @exclusive = false

  @getter 'subject', -> @__subject ||= @subjectBlock?.call(@context)
  @getter 'failed', -> @result?.state in ['skipped', 'errored', 'failure']
  @getter 'succeed', -> @result?.state is 'success'
  @getter 'reason', -> @afterReason or @examplePromise?.reason
  @getter 'duration', ->
    if @runEndedAt? and @runStartedAt?
      @runEndedAt.getTime() - @runStartedAt.getTime()
    else
      0
  @getter 'fullDescription', ->
    expectationsDescriptions = @result.expectations.map (e) -> e.description
    expectationsDescriptions = utils.literalEnumeration expectationsDescriptions
    "#{@description} #{expectationsDescriptions}"

  @getter 'ownDescriptionWithExpectations', ->
    return @result.state if @result.expectations.length is 0 and @ownDescription is ''
    expectationsDescriptions = @result.expectations.map (e) -> e.description
    expectationsDescriptions = utils.literalEnumeration expectationsDescriptions
    "#{@ownDescription} #{expectationsDescriptions}"

  @ancestorsScope 'identifiedAncestors', (e) -> e.options.id?

  pending: ->
    if @examplePromise?.pending
      @result.state = 'pending'
      @examplePromise.resolve()

  skip: ->
    if @examplePromise?.pending
      @result.state = 'skipped'
      error = new Error 'Skipped'
      if error.stack?
        stack = error.stack.split('\n')
        specIndex = spectacular.env.runner.findSpecFileInStack stack
        error.stack = stack[specIndex..].join('\n') if specIndex isnt -1

      @examplePromise.reject error

  resolve: =>
    if @examplePromise?.pending
      if @result.hasFailures()
        @result.state = 'failure'
        @examplePromise.reject()
      else if @result.expectationsCount() is 0
        @result.state = 'pending'
        @examplePromise.resolve()
      else
        @result.state = 'success'
        @examplePromise.resolve()

  reject: (reason) =>
    if @examplePromise?.pending
      @result.state = 'failure'
      @examplePromise.reject reason

  error: (reason) ->
    if @examplePromise?.pending
      @result.state = 'errored'
      @examplePromise.reject reason

  createContext: ->
    context = {}
    Object.defineProperty context, 'subject', get: => @subject
    context

  hasDependencies: -> @dependencies.length > 0

  dependenciesMet: -> true

  run: ->
    @runStartedAt = new Date()
    @context = @createContext()
    @examplePromise = new spectacular.Promise
    @result = new spectacular.ExampleResult this

    unless @dependenciesMet()
      @skip()
      return @examplePromise

    afterPromise = new spectacular.Promise

    @runBefore (err) =>
      @runEndedAt = new Date()
      return @error err if err?
      @executeBlock()

    @examplePromise.then => @runAfter (err) =>
      @runEndedAt = new Date()
      return @handleAfterError err, afterPromise if err?
      afterPromise.resolve()

    @examplePromise.fail (reason) => @runAfter (err) =>
      @runEndedAt = new Date()
      return @handleAfterError err, afterPromise if err?
      afterPromise.reject reason

    afterPromise

  handleAfterError: (error, promise) ->
    @result.state = 'errored'
    @afterReason = error
    promise.reject error

  runBefore: (callback) ->
    befores = @beforeHooks.concat()
    @runHooks befores, callback

  runAfter: (callback) ->
    afters = @afterHooks.concat()
    @runHooks afters, callback

  runHooks: (hooks, callback) ->
    next = (err) =>
      return callback err if err?
      if hooks.length is 0
        callback()
      else
        @executeHook hooks.shift(), next

    next()

  executeHook: (hook, next) ->
    try
      if @acceptAsync hook
        async = new spectacular.AsyncPromise
        async.then => next()
        async.fail (reason) => next reason
        async.run()
        hook.call(@context, async)
      else
        hook.call(@context)
        next()
    catch e
      next(e)

  executeBlock: ->
    return @pending() unless @block?

    try
      if @acceptAsync @block
        async = new spectacular.AsyncPromise
        async.then @executeExpectations, @reject
        async.fail (reason) => @error reason
        async.run()
        @block.call(@context, async)
      else
        @block.call(@context)
        @executeExpectations()
    catch e
      @error e

  executeExpectations: =>
    @result.promise.then @resolve, @reject

  toString: -> "[Example(#{@description})]"

  acceptAsync: (func) -> func.signature().length is 1

## ExampleGroup

class spectacular.ExampleGroup extends spectacular.Example
  @include spectacular.HasCollection('children', 'child')
  @include spectacular.HasNestedCollection('descendants', through: 'children')

  @filterGroups: (e) ->
    e.children? and not e.inclusive
  @filterExamples: (e) ->
    not e.children? and not e.inclusive
  @filterExclusiveExamples: (e) ->
    ExampleGroup.filterExamples(e) and e.exclusive


  @childrenScope 'exampleGroups', ExampleGroup.filterGroups
  @childrenScope 'examples', ExampleGroup.filterExamples
  @childrenScope 'exclusiveExamples', ExampleGroup.filterExclusiveExamples

  @descendantsScope 'allExamples', ExampleGroup.filterExamples
  @descendantsScope 'allExclusiveExamples', ExampleGroup.filterExclusiveExamples
  @descendantsScope 'allExamplesWithDependecies', (e) ->
    ExampleGroup.filterExamples(e) and e.hasDependencies()
  @descendantsScope 'allExclusiveExamplesWithDependecies', (e) ->
    ExampleGroup.filterExclusiveExamples(e) and e.hasDependencies()

  @descendantsScope 'identifiedExamples', (e) -> e.options?.id?
  @getter 'identifiedExamplesMap', ->
    res = {}
    res[e.options.id] = e for e in @identifiedExamples
    res
  @getter 'failed', -> @allExamples.some (e) -> e.failed
  @getter 'succeed', -> @allExamples.every (e) -> e.succeed
  @getter 'examplesSuceed', -> @examples.every (e) -> e.succeed

  @SUBJECTS_MAP = {
    '::': 'instanceMemberAsSubject'
    '#' : 'instanceMemberAsSubject'
    '.' : 'classMemberAsSubject'
  }


  constructor: (block, desc, @parent, @options={}) ->
    subject = null
    switch typeof desc
      when 'string'
        tokenNotFound = true
        for token, method of ExampleGroup.SUBJECTS_MAP
          if desc.indexOf(token) is 0
            @[method].call this, desc, token
            tokenNotFound = false

        if tokenNotFound and not @parent? or @parent.description is ''
          @noSpaceBeforeDescription = true
      else
        @noSpaceBeforeDescription = true
        subject = desc
        @subjectBlock = => subject

        desc = subject?.name or subject?._name or subject?.toString() or ''

    super block, desc, @parent
    @children = []

  run: ->

  classMemberAsSubject: (desc, token) ->
    @noSpaceBeforeDescription = true
    owner = @subject
    subject = owner?[desc.replace '.', '']
    if typeof subject is 'function'
      original = subject
      subject = -> original.apply owner, arguments

    @subjectBlock = -> subject

  instanceMemberAsSubject: (desc, token) ->
    @noSpaceBeforeDescription = true
    type = @subject
    @subjectBlock = ->
      subject = null
      if type
        owner = build type, @parameters or []
        subject = owner[desc.replace token, '']
        @owner = owner
        if typeof subject is 'function'
          original = subject
          subject = -> original.apply owner, arguments
      subject

  executeBlock: ->
    return it(-> pending()) unless @block?
    @block.call(this)
    it(-> pending()) if @allExamples.length is 0

  hasExclusiveExamples: -> @allExclusiveExamples.length > 0

  hasExamplesWithDependencies: ->
    @allExamples.some (e) -> e.hasDependencies()

  hasExclusiveExamplesWithDependencies: ->
    @allExclusiveExamples.some (e) -> e.hasDependencies()

  toString: -> "[ExampleGroup(#{@description})]"

