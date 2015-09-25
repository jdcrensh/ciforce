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
  describe = db.metadata.by 'directoryName', dir
  glob "#{dir}/*-meta.xml", cwd: "#{pkg}/src", (err, res) ->
    return cb err if err
    res.forEach (path) ->
      suffix = if (suffix = describe.suffix)? then ".#{suffix}" else ''
      files.push path[...path.lastIndexOf '-meta.xml'] + suffix
    cb()

buildComponentMap = (files) ->
  noMeta = minimatch.filter '!*-meta.xml', matchBase: on

  metadataTypeByPath = (path) ->
    db.metadata.by('directoryName', beforeSlash path).xmlName

  removeSuffix = (result, list, name) ->
    suffix = db.metadata.by('xmlName', name).suffix
    result[name] = list.map (path) ->
      path = path[path.indexOf('/') + 1..]
      # remove file ext from path
      if suffix?
        path = path[...path.lastIndexOf(suffix) - 1]
      path

  _(files).filter(noMeta).groupBy(metadataTypeByPath).transform(removeSuffix).value()

beforeSlash = (str) -> str[...str.indexOf path.sep]

afterSlash = (str) -> str[1 + str.indexOf(path.sep)..]

pkg_unarchive = (done, res) ->
  unzip = gulp.src "#{cwd}/#{pkg_zip}"
    .pipe unzip pkg
    .pipe gulp.dest pkg

  unzip.on 'end', done
  unzip.on 'error', done


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

  pkg: (done) ->
    async.auto
      diff: (done) ->
        args = "diff-tree -r --no-commit-id --name-status #{config.git.ref} #{config.git.branch}"
        git.exec {args, cwd, quiet}, (err, res) ->
          return done err if err
          # build array and filter out hidden files and package.xml
          _.words res.replace(/,/g, ''), /.+/g
            .filter minimatch.filter '!{.*,package.xml}', matchBase: on
            .forEach (line) ->
              [..., status, file] = /^(\w)\t(.*)/.exec line
              {root, dir, base, ext, name} = path.parse file
              obj = {}
              obj.path = file
              obj.status = status

              dir = dir.replace "src#{path.sep}", ''
              if ~dir.indexOf path.sep
                obj.directory = beforeSlash dir
                obj.folder = afterSlash dir
                obj.member = "#{obj.folder}/#{base}"
              else
                obj.directory = dir
                obj.member = base

              describe = db.metadata.by 'directoryName', obj.directory
              obj.member = obj.member.replace ".#{describe.suffix}", ''
              db.diff.insert obj
          done()

      archive: ['diff', (done) ->
        changes = db.findChangedPaths()
        # TODO: include -meta.xml and components where meta.xml files have changed...
        args = "archive -0 -o #{pkg_zip} #{config.git.branch} '#{changes.join('\' \'')}'"
        git.exec {args, cwd, quiet}, done
      ]

      unarchive: ['archive', pkg_unarchive]

      packageXml: ['unarchive', (done, res) ->
        changes = db.findChangedPaths().map (path) -> path[4..]
        async.each db.directories(), includeFolders(changes), ->
          xml.writePackage buildComponentMap(changes), "#{pkg}/src/package.xml"
          done()
      ]

      packageDestructiveXml: ['diff', (done, res) ->
        deleted = db.findDeletedPaths().map (path) -> path[4..]
        async.each db.directories(), includeFolders(deleted), (err) ->
          xml.writePackage buildComponentMap(deleted), "#{pkg}/src/destructiveChangesPost.xml"
          done err
      ]
    , done


module.exports = new GitModule()
