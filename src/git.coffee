pkg       = require '../package.json'
config    = require './config'
db        = require './db'
log       = require './log'
xml       = require './xml'
_         = require 'lodash'
async     = require 'async'
del       = require 'del'
fs        = require 'fs-extra'
git       = require 'gulp-git'
glob      = require 'glob'
gulp      = require 'gulp'
minimatch = require 'minimatch'
path      = require 'path'
unzip     = require 'gulp-unzip'

# repo directory
cwd = 'repo'

# package directory
pkg = 'pkg'

# package zip filename
pkg_zip = 'pkg.zip'

# git quite mode
quiet = true

includeFolders = (files) -> (dir, cb) ->
  describe = db.metadata.findObject directoryName: dir
  glob "#{dir}/*-meta.xml", cwd: "#{pkg}/src", (err, res) ->
    return cb err if err
    res.forEach (path) ->
      suffix = if (suffix = describe.suffix)? then ".#{suffix}" else ''
      files.push path[...path.lastIndexOf '-meta.xml'] + suffix
    cb()

buildComponentMap = (files) ->
  noMeta = minimatch.filter '!*-meta.xml', matchBase: on

  metadataTypeByPath = (path) ->
    db.metadata.findObject(directoryName: beforeSlash path).xmlName

  removeSuffix = (result, list, name) ->
    suffix = db.metadata.findObject(xmlName: name).suffix
    result[name] = list.map (path) ->
      path = path[path.indexOf('/') + 1..]
      # remove file ext from path
      if suffix? then path[...path.lastIndexOf(suffix) - 1] else path

  _(files).filter(noMeta).groupBy(metadataTypeByPath).transform(removeSuffix).value()

beforeSlash = (str) -> str[...str.indexOf path.sep]

afterSlash = (str) -> str[1 + str.indexOf(path.sep)..]


class GitModule

  repo: (done) ->
    fs.ensureDirSync cwd
    async.waterfall [
      (done) ->
        args = 'config remote.origin.url'
        git.exec {args, cwd, quiet}, done
      (res, done) ->
        if _.trim(res) is config.git.url
          async.series [
            (done) -> git.fetch '', '', {args: '--all --tags', cwd}, done
            (done) -> git.checkout config.git.branch, {args: '-f', cwd}, done
            (done) -> git.reset "origin/#{config.git.branch}", {args: '--hard', cwd}, done
            (done) -> git.exec {args: 'clean -fd', cwd, log: true}, done
          ], done
        else
          del cwd
          git.clone config.git.url, args: "--branch=#{config.git.branch} #{cwd}", done
    ], done
    return

    # include -meta.xml files where components have changed
    # include components where meta.xml files have changed

  pkg: (done) ->
    async.auto
      diff: (done) ->
        args = "diff-tree -r --no-commit-id --name-status #{config.git.ref} #{config.git.branch}"
        git.exec {args, cwd, quiet}, (err, res) ->
          return done err if err
          # build changes array
          toUpdate = {}
          toInsert = []
          _.words res.replace(/,/g, ''), /.+/g
            .filter minimatch.filter '!{.*,package.xml}', matchBase: on
            .forEach (line) ->
              [..., diffStatus, fileName] = /^(\w)\tsrc\/(.*)/.exec line
              obj = db.components.findObject fileName: fileName.replace /-meta\.xml$/, ''
              if obj
                obj.diffStatus = diffStatus
                toUpdate[obj.$loki] = obj
              else if diffStatus isnt 'D' and not fileName.match /-meta\.xml$/
                {dir, base} = path.parse fileName
                obj = {fileName, diffStatus}
                if ~dir.indexOf path.sep
                  directory = beforeSlash dir
                  obj.fullName = "#{afterSlash dir}/#{base}"
                else
                  directory = dir
                  obj.fullName = base

                describe = db.metadata.findObject directoryName: directory
                if suffix = describe.suffix
                  obj.fullName = obj.fullName.replace new RegExp("\.#{suffix}$"), ''
                obj.type = describe.xmlName

                toInsert.push obj
          db.components.insert toInsert
          db.components.update _.values toUpdate
          done()

      archive: ['diff', (done) ->
        metaTypes = _.pluck db.metadata.find(metaFile: true), 'xmlName'
        changeset = db.components.find $and: [
          managableState: $ne: 'installed'
        ,
          diffStatus: $in: 'ACMRT'.split ''
        ]
        changeset.reduce (arr, obj) ->
          arr.push "src/#{obj.fileName}"
          arr.push "src/#{obj.fileName}-meta.xml" if obj.type in metaTypes
          return arr
        , []
        # console.log changeset
        args = "archive -0 -o #{pkg_zip} #{config.git.branch} '#{changeset.join('\' \'')}'"
        git.exec {args, cwd, quiet}, done
      ]

      unarchive: ['archive',  (done, res) ->
        unzip = gulp.src "#{cwd}/#{pkg_zip}"
          .pipe unzip pkg
          .pipe gulp.dest pkg
        unzip.on 'end', done
        unzip.on 'error', done
      ]

      packageXml: ['unarchive', (done, res) ->
        changes = db.findChanges().map (obj) -> obj.path[4..]
        async.each db.findDirectories(), includeFolders(changes), ->
          xml.writePackage buildComponentMap(changes), "#{pkg}/src/package.xml"
          done err
      ]

      packageDestructiveXml: ['diff', (done, res) ->
        deleted = db.findDeletes().map (obj) -> obj.path[4..]
        async.each db.findDirectories(), includeFolders(deleted), (err) ->
          xml.writePackage buildComponentMap(deleted), "#{pkg}/src/destructiveChangesPost.xml"
          done err
      ]
    , done


module.exports = new GitModule()
