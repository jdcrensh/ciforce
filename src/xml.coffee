# local libs
{config} = require('require-dir')()

# ext modules
_           = require 'lodash'
fs          = require 'fs-extra'
{pd}        = require 'pretty-data'
{DOMParser} = require 'xmldom'

class PackageXml
  constructor: (version) ->
    @doc = new DOMParser().parseFromString '<?xml version="1.0" encoding="UTF-8"?><Package/>'

    @doc.documentElement.setAttribute 'xmlns', 'http://soap.sforce.com/2006/04/metadata'
    @doc.documentElement.appendChild @doc.createElement 'version'
      .appendChild @doc.createTextNode version

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

  write: (path, done) ->
    fs.outputFile path, pd.xml(@doc.toString()), done


class XmlModule

  writePackage: (components, version, path, done) ->
    doc = new PackageXml(version)
    # append type nodes
    doc.addTypes types = Object.keys components
    # append members to type nodes
    types.forEach (type) -> doc.addMembers type, components[type]
    # write to file
    doc.write path, done
    return


module.exports = new XmlModule()
