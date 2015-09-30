# local libs
{config, db} = require('require-dir')()

# ext modules
_        = require 'lodash'
async    = require 'async'
jsforce  = require 'jsforce'
gutil    = require 'gulp-util'

con = deployResult = lastDeployResult = null


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
    gutil.log do ->
      if @success is 'SucceededPartial'
        'Deployment patially succeeded.'
      else if @success
        'Deploy succeeded.'
      else if @done
        'Deploy failed.'
      else
        'Deploy not completed yet.'

    if @errorMessage
      gutil.log "#{@errorStatusCode}: #{@errorMessage}"

    gutil.log()
    gutil.log "Id: #{@id}"
    gutil.log "Status: #{@status}"
    gutil.log "Success: #{@success}"
    gutil.log "Done: #{@done}"
    gutil.log "Component Errors: #{@numberComponentErrors}"
    gutil.log "Components Deployed: #{@numberComponentsDeployed}"
    gutil.log "Components Total: #{@numberComponentsTotal}"
    gutil.log "Test Errors: #{@numberTestErrors}"
    gutil.log "Tests Completed: #{@numberTestsCompleted}"
    gutil.log "Tests Total: #{@numberTestsTotal}"

    @reportDeployResultDetails @details

  reportDeployResultDetails: (details) ->
    if details
      gutil.log('')
      failures = _.flatten [details.componentFailures]
      if failures
        if failures.length
          gutil.log 'Failures:'

        failures.forEach (f) ->
          gutil.log " - #{f.problemType} on #{f.fileName} : #{f.problem}"

      if process.verbose
        successes = _.flatten [details.componentSuccesses]
        if successes.length
          gutil.log 'Successes:'

        successes.forEach (s) ->
          flag = switch 'true'
            when "#{s.changed}" then '(M)'
            when "#{s.created}" then '(A)'
            when "#{s.deleted}" then '(D)'
            else '(~)'
          gutil.log " - #{flag} #{s.fileName}#{if s.componentType then ' [' + s.componentType + ']' else ''}"


class RunTestResult

  constructor: (deployResult) ->
    _.assign @, deployResult.details?.runTestResult ? {}
    @failures = _.compact [@failures] unless _.isArray @failures

  getRecentFailures: (old) ->
    if old?.numFailures then @failures[old.numFailures..] else []

  reportFailures: (failures) ->
    return unless failures?.length
    sep = _.repeat '-', 80
    gutil.log sep
    gutil.log 'Test Failures:'
    failures.forEach (failure, i) ->
      indent = _.repeat ' ', (num = "#{i + 1}. ").length
      gutil.log "#{num}#{failure.name}.#{failure.methodName}"
      gutil.log indent + failure.message
      failure.stackTrace.split('\n').forEach (line) -> gutil.log indent + "#{line}"
    gutil.log sep

  report: ->


class ComponentResults
  constructor: (deployResult) ->
    @successes = deployResult.details?.componentSuccesses ? []

  getRecentFailures: (old) -> []

  reportFailures: (failures) ->
    return unless failures?.length
    failures.forEach (f) ->

  report: ->


updateDeployResult = (res) ->
  [lastDeployResult, deployResult] = [deployResult, new DeployResult res]

getDeployResult = ->
  deployResult ? {}

getRunTestResult = ->
  deployResult?.runTestResult ? {}

getComponentResults = ->
  deployResult?.componentResults ? {}

typeQueries = ->
  db.metadata.find().map (obj) ->
    type: obj.xmlFolderName ? obj.xmlName

folderQueries = ->
  folderTypes = _.indexBy db.metadata.find(inFolder: true), 'xmlFolderName'
  db.components.find(type: $in: Object.keys folderTypes).map (obj) ->
    type: folderTypes[obj.type].xmlName
    folder: obj.fullName

listQuery = (query, next) ->
  con.metadata.list query, (err, res) ->
    db.components.insert res if res?
    next err

module.exports =
  login: ->
    username = if config.sfdc.sandbox
      "#{config.sfdc.username}.#{config.sfdc.sandbox}"
    else
      config.sfdc.username

    con = new jsforce.Connection
      loginUrl: "https://#{['login', 'test'][~~!!config.sfdc.sandbox]}.salesforce.com"
      version: config.sfdc.version

    con.login username, "#{config.sfdc.password}#{config.sfdc.securitytoken}"

  describeMetadata: ->
    con.metadata.describe().then (res) ->
      db.metadata.insert res.metadataObjects

  describeGlobal: ->
    con.describeGlobal().then (res) ->
      db.global.insert res.sobjects

  listMetadata: (done) ->
    async.series
      # retrieve metadata listings in chunks
      one: (next) -> async.each _.chunk(typeQueries(), 3), listQuery, next
      # retrieve folder contents
      two: (next) -> async.each _.chunk(folderQueries(), 3), listQuery, next
    , done

  validate: (done) ->
    archive = require('archiver') 'zip'
    archive.directory 'pkg', ''
    archive.finalize()

    deploy = con.metadata.deploy archive,
      checkOnly: true
      purgeOnDelete: true
      rollbackOnError: true
      runAllTests: false
      testLevel: 'RunLocalTests'

    async.during (done) ->
      res = getDeployResult()
      if res.id
        con.metadata.checkDeployStatus res.id, true, (err, res) ->
          return done err, false if err
          res = updateDeployResult res
          res.reportFailures()

          msg = res.statusMessage()
          if msg and res.statusMessage() isnt msg
            if res.done
              gutil.log gutil.colors[if res.success then 'green' else 'red'] msg
            else
              gutil.log msg
          done null, !res.done
      else
        deploy.check (err, res) ->
          updateDeployResult res
          done err, !err
    , (next) ->
      setTimeout next, 1000
    , (err) ->
      res = getDeployResult()
      res.report()
      done err ? res.success
      return

  retrieve: (done) ->
    con.metadata.retrieve(packageNames: 'unpackaged').then (res) ->
      gutil.log res
      res.pipe fs.createWriteStream 'pkg.zip'
      done()
    , (err) ->
      done err
