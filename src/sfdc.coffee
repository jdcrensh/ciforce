config   = require './config'
db       = require './db'
log      = require './log'
_        = require 'lodash'
async    = require 'async'
jsforce  = require 'jsforce'


class DeployResult

  constructor: (data={}) ->
    _.assign @, data
    @runTestResult = new RunTestResult @
    @componentResults = new ComponentResults @

  statusMessage: ->
    msg = ''
    method = ['Deployment', 'Validation'][~~@checkOnly]
    if @status?
      status = switch @status
        when 'InProgress' then 'In Progress'
        when 'Pending' then 'Waiting for other deployments to finish'
        else @status

      msg += status

      msg += switch status
        when 'Canceled' then " by #{@canceledByName}"
        when 'Canceling' then ''
        else
          if @stateDetail? then " -- #{@stateDetail}" else ''
    msg

  getRecentFailures: (old) ->
    components: @componentResults.getRecentFailures old.componentResults
    tests: @runTestResult.getRecentFailures old.runTestResult

  reportFailures: (failures={}) ->
    if failures.components?.length
      @componentResults.reportFailures failures.components
    if failures.tests?.length
      @runTestResult.reportFailures failures.tests

  report: ->
    log.writeln do ->
      if @success is 'SucceededPartial'
        'Deployment patially succeeded.'
      else if @success
        'Deploy succeeded.'
      else if @done
        'Deploy failed.'
      else
        'Deploy not completed yet.'

    if @errorMessage
      log.writeln "#{@errorStatusCode}: #{@errorMessage}"

    log.writeln()
    log.writeln "Id: #{@id}"
    log.writeln "Status: #{@status}"
    log.writeln "Success: #{@success}"
    log.writeln "Done: #{@done}"
    log.writeln "Component Errors: #{@numberComponentErrors}"
    log.writeln "Components Deployed: #{@numberComponentsDeployed}"
    log.writeln "Components Total: #{@numberComponentsTotal}"
    log.writeln "Test Errors: #{@numberTestErrors}"
    log.writeln "Tests Completed: #{@numberTestsCompleted}"
    log.writeln "Tests Total: #{@numberTestsTotal}"

    @reportDeployResultDetails @details

  reportDeployResultDetails: (details) ->
    if details
      log.writeln()
      failures = _.flatten [details.componentFailures]
      if failures
        if failures.length
          log.writeln 'Failures:'

        failures.forEach (f) ->
          log.writeln " - #{f.problemType} on #{f.fileName} : #{f.problem}"

      if process.verbose
        successes = _.flatten [details.componentSuccesses]
        if successes.length
          log.writeln 'Successes:'

        successes.forEach (s) ->
          flag = switch 'true'
            when "#{s.changed}" then '(M)'
            when "#{s.created}" then '(A)'
            when "#{s.deleted}" then '(D)'
            else '(~)'
          log.writeln " - #{flag} #{s.fileName}#{if s.componentType then ' [' + s.componentType + ']' else ''}"


class RunTestResult

  constructor: (deployResult) ->
    _.assign @, deployResult.details?.runTestResult ? {}
    @failures = _.compact [@failures] unless _.isArray @failures

  getRecentFailures: (old) ->
    if old?.numFailures then @failures[old.numFailures..] else []

  reportFailures: (failures) ->
    return unless failures?.length
    err = [_.repeat('-', 80), 'Test Failures:']
    failures.forEach (failure, i) ->
      stackTrace = _(failure.stackTrace.split '\n').map (line) -> "   #{line}"
      err.push """
        #{i + 1}. #{failure.name}.#{failure.methodName}
           #{failure.message}
        #{stackTrace.join '\n'}
      """
    err.push _.repeat '-', 80
    log.writelns err.join '\n'

  report: ->


class ComponentResults
  constructor: (deployResult) ->
    @successes = deployResult.details?.componentSuccesses ? []

  getRecentFailures: (old) -> []

  reportFailures: (failures) ->
    return unless failures?.length
    failures.forEach (f) ->

  report: ->


class SfdcModule
  # logs error and returns normal callback
  asyncContinue: (done) -> (err) ->
    log.error err if err
    done()

  updateDeployResult: (res) ->
    [@lastDeployResult, @deployResult] = [@deployResult, new DeployResult res]

  getDeployResult: ->
    @deployResult ? {}

  getRunTestResult: ->
    @deployResult?.runTestResult ? {}

  getComponentResults: ->
    @deployResult?.componentResults ? {}

  login: ->
    username = if config.sfdc.sandbox
      "#{config.sfdc.username}.#{config.sfdc.sandbox}"
    else
      config.sfdc.username

    @con = new jsforce.Connection
      loginUrl: "https://#{['login', 'test'][~~!!config.sfdc.sandbox]}.salesforce.com"
      version: config.sfdc.version

    @con.login username, "#{config.sfdc.password}#{config.sfdc.securitytoken}"

  describeMetadata: ->
    @con.metadata.describe().then (res) ->
      db.metadata.insert res.metadataObjects

  describeGlobal: ->
    @con.describeGlobal().then (res) ->
      db.global.insert res.sobjects

  listMetadata: (done) ->
    log.write 'Listing metadata properties...'
    types = db.metadata.find()

    async.each types, (type, done) =>
      name = type.xmlFolderName ? type.xmlName

      @con.metadata.list(type: name).then (items) =>
        return done() unless items?
        db.insertComponents items
        log.ok "#{name} (#{items.length ? 1})"
        return done() unless type.inFolder
        async.each _.flatten([items]), (folder, done) =>
          @con.metadata.list(type: name, folder: folder.fullName).then (folderItem) ->
            return done() unless folderItem?
            db.insertComponents folderItem
            log.ok "#{name}: #{folder.fullName} (#{folderItem.length ? 1})"
          , @asyncContinue done
        , @asyncContinue done
      , done
    , done

  validate: (done) ->
    archive = require('archiver') 'zip'
    archive.directory 'pkg', ''
    archive.finalize()

    deploy = @con.metadata.deploy archive,
      checkOnly: true
      purgeOnDelete: true
      rollbackOnError: true
      runAllTests: false
      testLevel: 'RunLocalTests'

    async.during (done) =>
      res = @getDeployResult()
      if res.id
        @con.metadata.checkDeployStatus res.id, true, (err, res) =>
          return done err, false if err
          res = @updateDeployResult res
          res.reportFailures()

          msg = res.statusMessage()
          if msg and res.statusMessage() isnt msg
            if res.done
              if res.success then log.ok msg
              else log.error msg
            else
              log.writeln msg
          done null, !res.done
      else
        deploy.check (err, res) =>
          @updateDeployResult res
          done err, !err
    , (next) ->
      setTimeout next, 1000
    , (err) =>
      res = @getDeployResult()
      res.report()
      done err ? res.success
    return

  retrieve: (done) ->
    @con.metadata.retrieve(packageNames: 'unpackaged').then (res) ->
      log.writeln res
      res.pipe fs.createWriteStream 'pkg.zip'
      done()
    , (err) ->
      done err


module.exports = new SfdcModule()
