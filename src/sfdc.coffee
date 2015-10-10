async        = require 'async'
gulp         = require 'gulp'
gutil        = require 'gulp-util'
path         = require 'path'
zip          = require 'gulp-zip'
_            = require 'lodash'
console      = require 'better-console'

{config, db, events, jsforce} = require('require-dir') '.', recurse: true

conn = deployResult = lastDeployResult = canceled = null

jsforceOpts =
  username: if config.sfdc.sandbox
    "#{config.sfdc.username}.#{config.sfdc.sandbox}"
  else
    config.sfdc.username
  password: "#{config.sfdc.password}#{config.sfdc.securitytoken}"
  loginUrl: "https://#{['login', 'test'][~~!!config.sfdc.sandbox]}.salesforce.com"
  version: config.sfdc.version
  logger: gutil

handleError = (err, done) ->
  gutil.log gutil.colors.red err
  done err, false

updateDeployResult = (res) ->
  [lastDeployResult, deployResult] = [deployResult, new jsforce.deploy.DeployResult res]
  deployResult

getDeployResult = ->
  deployResult ? {}

getCancelDeployResult = ->
  cancelDeployResult ? {}

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
  conn.metadata.list query, (err, res) ->
    db.components.insert res if res?
    next err

exitHandler = (options={}, err) -> ->
  if options.cancel and (res = getDeployResult())?.id
    canceled = true
    conn.metadata._invoke 'cancelDeploy', id: res.id
  else
    process.exit()

process.on 'exit', exitHandler()
process.on 'SIGINT', exitHandler cancel: true
process.on 'uncaughtException', exitHandler()

deployComplete = (err, res, done) ->
  return handleError err, done if err
  res = getDeployResult()
  res.report()
  done res.success
  process.exit() if canceled

module.exports =
  login: (done) ->
    jsforce.connect(jsforceOpts).then (_conn) ->
      jsforce.deploy.connection conn = _conn
    .catch (err) -> throw err

  describeMetadata: (done) ->
    conn.metadata.describe().then (res) ->
      db.metadata.insert res.metadataObjects
    .catch (err) -> throw err

  describeGlobal: (done) ->
    conn.describeGlobal().then (res) ->
      db.global.insert res.sobjects
    .catch (err) -> throw err

  listMetadata: (done) ->
    async.series
      # retrieve metadata listings in chunks
      one: (next) -> async.each _.chunk(typeQueries(), 3), listQuery, next
      # retrieve folder contents
      two: (next) -> async.each _.chunk(folderQueries(), 3), listQuery, next
    , done

  validate: (done) ->
    process.stdin.resume()

    async.during (done) ->
      res = getDeployResult()
      if res.id
        conn.metadata.checkDeployStatus(res.id, true).then (res) ->
          res = updateDeployResult res
          # res.reportFailures res.getRecentFailures lastDeployResult
          # if lastDeployResult.lastModifiedDate isnt res.lastModifiedDate
          console.log res
          msg = res.statusMessage()
          if msg# and lastDeployResult.statusMessage() isnt msg
            if res.done
              gutil.log gutil.colors[if res.success then 'green' else 'red'] msg
            else
              gutil.log msg
          done null, not res.done
        .catch (err) -> throw err
      else
        jsforce.deploy.deployFromDirectory path.join(config.git.dir, 'src'),
          checkOnly: true
          purgeOnDelete: true
          rollbackOnError: true
          runAllTests: false
          testLevel: 'RunLocalTests'
        .check (err, res) ->
          throw err if err
          gutil.log updateDeployResult(res).statusMessage()
          done err, true
    , (next) ->
      setTimeout next, 1000
    , (err) ->
      deployComplete err, done

  retrieve: (done) ->
    conn.metadata.retrieve(packageNames: 'unpackaged').then (res) ->
      gutil.log res
      res.pipe fs.createWriteStream 'pkg.zip'
      done()
    .catch (err) -> throw err
