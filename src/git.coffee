async     = require 'async'
del       = require 'del'
fs        = require 'fs-extra'
git       = require 'gulp-git'
glob      = require 'glob'
gulp      = require 'gulp'
minimatch = require 'minimatch'
path      = require 'path'
pkg       = require '../package.json'
unzip     = require 'gulp-unzip'
_         = require 'lodash'

{config, db, xml} = do require 'require-dir'

# package directory
pkg = path.resolve 'pkg'
# package zip path
pkg_zip = path.resolve 'pkg.zip'
# git quite mode
quiet = true

{version} = config.sfdc
{branch}  = config.git
cwd       = config.git.dir # repo directory
repourl   = config.git.url
gitref    = config.git.ref

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

    obj = {fileName, diffStatus, fullName: path.join subpath, base}

    if suffix = describe.suffix
      obj.fullName = obj.fullName.replace new RegExp("\\.#{suffix}$"), ''
    obj.type = describe.xmlName

  return obj

# parse git diff output
parseDiff = (res) ->
  diff = _.chain res.replace /,/g, ''
    .words /.+/g
    .map (line) -> [(res = /^(\w)\t(.*)/.exec line)[1], path.shift(res[2])[1]]
    .filter _.modArgs minimatch.filter('!{.*,package.xml}', matchBase: true), (line) -> line[1]
    .map parseLine
    .compact()
    .groupBy (obj) -> if obj.$loki? then 'updates' else 'inserts'
    .value()

  # insert/update parsed diff output
  db.components.insert diffs.inserts
  db.components.update _.uniq diffs.updates, (obj) -> obj.$loki

  # diff completed
  changes = db.components.find diffStatus: $in: 'ACMRT'.split ''
  deletes = db.components.find diffStatus: 'D'
  {changes, deletes}


forEachRemoteBranch = (iteratee, done) ->
  git.exec {cwd, args: 'branch -a', quiet: true}, (err, res) ->
    return done err, res if err
    branches = res.split '\n'
      .filter (line) -> line.match(/remotes\//) and not line.match(/->/)
      .map (line) -> _.trim(line).replace /^remotes\/[^\/]+\//, ''
    async.each branches, iteratee, done

pkg_diff = (done) ->
  # execute the git-diff-tree command
  args = "diff-tree -r --no-commit-id --name-status #{gitref} #{branch}"
  git.exec {args, cwd, quiet}, (err, res) -> if err then done err else done null, parseDiff res

pkg_archive = (done, res) ->
  metaTypes = _.pluck db.metadata.find(metaFile: true), 'xmlName'
  changeset = res.diff.changes.reduce (arr, obj) ->
    arr.push path.join 'src', obj.fileName
    arr.push path.join 'src', "#{obj.fileName}-meta.xml" if obj.type in metaTypes
    return arr
  , []
  args = "archive -0 -o #{pkg_zip} #{branch} '#{changeset.join('\' \'')}'"
  git.exec {args, cwd, quiet}, (err) -> done err, changeset

pkg_unarchive = (done) ->
  unzip = gulp.src pkg_zip
    .pipe unzip pkg
    .pipe gulp.dest pkg
  complete = -> del pkg_zip; done()
  unzip.on 'end', complete
  unzip.on 'error', complete

pkg_packageXml = (done, res) ->
  dest = path.join pkg, 'src', 'package.xml'
  members = _(res.diff.changes).groupBy('memberType').mapPlucked('fullName').value()
  xml.writePackage members, version, dest, done

pkg_packageDestructiveXml = (done, res) ->
  dest = path.join pkg, 'src', 'destructiveChangesPost.xml'
  members = _(res.diff.deletes).groupBy('memberType').mapPlucked('fullName').value()
  xml.writePackage members, version, dest, done

module.exports =
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
            (done) ->
              forEachRemoteBranch (branch, done) ->
                if branch is gitref
                  git.checkout gitref, {args: '-f', cwd}, done
                else
                  async.setImmediate done
              , done
            (done) -> git.checkout branch, {args: '-f', cwd}, done
            (done) -> git.reset "origin/#{branch}", {args: '--hard', cwd}, done
            (done) -> git.exec {args: 'clean -fd', cwd, log: true}, done
          ], done
        else
          del cwd
          git.clone repourl, args: "--branch=#{branch} #{cwd}", done
          throw 'error!'
    ], (err) ->
      throw err if err
      done()

  pkg: (done) ->
    async.auto
      diff: pkg_diff
      archive: ['diff', pkg_archive]
      unarchive: ['archive', pkg_unarchive]
      packageXml: ['unarchive', pkg_packageXml]
      packageDestructiveXml: ['diff', pkg_packageDestructiveXml]
    , done
