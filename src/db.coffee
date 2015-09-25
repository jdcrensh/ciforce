Loki = require 'lokijs'


class DbModule

  folderOverrides:
    EmailTemplate: 'Email'

  constructor: ->
    @loki = new Loki()

    # git file diffs
    @diff = @loki.addCollection 'diff'

    @diff.on 'insert', (obj) ->
      obj.added = obj.status is 'A'
      obj.changed = obj.status is 'C'
      obj.deleted = obj.status is 'D'
      obj.modified = obj.status is 'M'
      obj.renamed = obj.status is 'R'
      obj.typechange = obj.status is 'T'
      obj.unmerged = obj.status is 'U'
      obj.unknown = obj.status is 'X'
      obj.pairingbroken = obj.status is 'B'
      return

    # global metadata describe
    @metadata = @loki.addCollection 'metadataDescribe',
      indices: ['xmlName', 'directoryName']
      unique: ['xmlName', 'directoryName']

    @metadata.on 'insert', (obj) =>
      if obj.inFolder
        obj.xmlFolderName = (@folderOverrides[obj.xmlName] ? obj.xmlName) + 'Folder'
      return

    # org components describe
    @components = @loki.addCollection 'componentDescribe'

    @components.on 'insert', (obj) =>
      if obj.type is 'CustomObjectTranslation'
        state_ind = if @isManaged obj then 'installed' else 'unmanaged'
      obj.managableState = states[state_ind]
      return

    # org sobjects describe
    @global = @loki.addCollection 'globalDescribe'

    # deploy results for components
    @componentResult = @loki.addCollection 'componentResult'

    # deploy results for tests
    @runTestResult = @loki.addCollection 'runTestResult'

  insertComponent: (item) ->
    @components.insert item

  pathsByStatus: (statuses...) ->
    statuses = statuses.map (status) -> "#{status}": true
    predicate = if statuses.length > 1 then '$or': statuses else statuses[0]
    @diff.find(predicate).map (obj) -> obj.path

  findChangedPaths: ->
    @pathsByStatus 'added', 'changed', 'modified'

  findDeletedPaths: ->
    @pathsByStatus 'deleted'

  directories: ->
    @metadata.find().map (obj) -> obj.directoryName


module.exports = new DbModule()
