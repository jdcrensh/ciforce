# local libs
{config, db, xml} = require('require-dir')()

# package object
pkg = require '../package.json'

# ext modules
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

cwd = 'repo'        # repo directory
pkg = 'pkg'         # package directory
pkg_zip = 'pkg.zip' # package zip filename
quiet = true        # git quite mode

version = config.sfdc.version
branch = config.git.branch
repourl = config.git.url
gitref = config.git.ref

class GitModule

  repo: (done) ->
    fs.ensureDirSync cwd
    async.waterfall [
      (done) ->
        args = 'config remote.origin.url'
        git.exec {args, cwd, quiet}, done
      (res, done) ->
        if repourl is _.trim res
          async.series [
            (done) -> git.fetch '', '', {args: '--all --tags', cwd}, done
            (done) -> git.checkout branch, {args: '-f', cwd}, done
            (done) -> git.reset "origin/#{branch}", {args: '--hard', cwd}, done
            (done) -> git.exec {args: 'clean -fd', cwd, log: true}, done
          ], done
        else
          del cwd
          git.clone repourl, args: "--branch=#{branch} #{cwd}", done
    ], done
    return

    # include -meta.xml files where components have changed
    # include components where meta.xml files have changed

  pkg: (done) ->
    async.auto
      diff: (done) ->
        parseLine = (line) ->
          [diffStatus, fileName] = line

          # locate the file object by its fileName and update diffStatus if found
          if (obj = db.components.findObject fileName: fileName.replace /-meta\.xml$/, '')?
            obj.diffStatus = diffStatus

          # parsing the diff's file path to generate a new file object.
          # note: the file isn't in the org so parsing deletes here is not necessary
          else if diffStatus isnt 'D' and not fileName.match /-meta\.xml$/
            {dir, base} = path.parse fileName
            [dir, subpath] = path.shift dir

            unless (describe = db.metadata.findObject directoryName: dir)?
              console.log "Unable to locate describe for directoryName: #{dir}"
              return

            obj = {fileName, diffStatus}
            obj.fullName = path.join subpath, base

            if suffix = describe.suffix
              obj.fullName = obj.fullName.replace new RegExp("\\.#{suffix}$"), ''
            obj.type = describe.xmlName

          return obj

        # execute the git-diff-tree command
        args = "diff-tree -r --no-commit-id --name-status #{gitref} #{branch}"
        git.exec {args, cwd, quiet}, (err, res) ->
          return done err if err

          # parse the diff output
          diffs = _.chain res.replace /,/g, ''
            .words(/.+/g).map (line) -> [(res = /^(\w)\t(.*)/.exec line)[1], path.shift(res[2])[1]]
            .filter _.modArgs minimatch.filter('!{.*,package.xml}', matchBase: true), (line) -> line[1]
            .map(parseLine).compact()
            .groupBy (obj) -> if obj.$loki? then 'updates' else 'inserts'
            .value()

          # insert/update parsed diff output
          db.components.insert diffs.inserts
          db.components.update _.uniq diffs.updates, (obj) -> obj.$loki

          # diff completed
          done null,
            changes: db.components.find diffStatus: $in: 'ACMRT'.split ''
            deletes: db.components.find diffStatus: 'D'

      archive: ['diff', (done, res) ->
        metaTypes = _.pluck db.metadata.find(metaFile: true), 'xmlName'
        changeset = res.diff.changes.reduce (arr, obj) ->
          arr.push "src/#{obj.fileName}"
          arr.push "src/#{obj.fileName}-meta.xml" if obj.type in metaTypes
          return arr
        , []
        # console.log changeset
        args = "archive -0 -o #{pkg_zip} #{branch} '#{changeset.join('\' \'')}'"
        git.exec {args, cwd, quiet}, (err) -> done err, changeset
      ]

      unarchive: ['archive',  (done) ->
        unzip = gulp.src "#{cwd}/#{pkg_zip}"
          .pipe unzip pkg
          .pipe gulp.dest pkg
        unzip.on 'end', done
        unzip.on 'error', done
      ]

      packageXml: ['unarchive', (done, res) ->
        dest = "#{pkg}/src/package.xml"
        members = _(res.diff.changes).groupBy('type').mapPlucked('fullName').value()
        xml.writePackage members, version, dest, done
      ]

      packageDestructiveXml: ['diff', (done, res) ->
        dest = "#{pkg}/src/destructiveChangesPost.xml"
        members = _(res.diff.deletes).groupBy('type').mapPlucked('fullName').value()
        xml.writePackage members, version, dest, done
      ]
    , done


module.exports = new GitModule()
