config      = require './config'
_           = require 'lodash'
fs          = require 'fs-extra'
{pd}        = require 'pretty-data'
{DOMParser} = require 'xmldom'


class PackageXml
  constructor: ->
    @doc = new DOMParser().parseFromString '<?xml version="1.0" encoding="UTF-8"?><Package/>'

    @doc.documentElement.setAttribute 'xmlns', 'http://soap.sforce.com/2006/04/metadata'
    @doc.documentElement.appendChild @doc.createElement 'version'
      .appendChild @doc.createTextNode config.sfdc.version

  addTypes: (types) ->
    @nodes ?= {}
    _.uniq(types.sort(), true).forEach (type) =>
      @nodes[type] = @doc.documentElement
        .appendChild @doc.createElement 'types'
        .appendChild @doc.createElement 'name'
        .appendChild @doc.createTextNode type
        .parentNode
        .parentNode
      return

  addMembers: (type, members) ->
    return unless (type_node = @nodes[type])?
    _.uniq(members.sort(), true).forEach (member) =>
      type_node
        .appendChild @doc.createElement 'members'
        .appendChild @doc.createTextNode member
      return

  write: (path) ->
    fs.outputFileSync path, pd.xml @doc.toString()


class XmlModule

  writePackage: (components, path) ->
    doc = new PackageXml()
    # append type nodes
    doc.addTypes types = Object.keys components
    # append members to type nodes
    types.forEach (type) -> doc.addMembers type, components[type]
    # write to file
    doc.write path
    return


module.exports = new XmlModule()
