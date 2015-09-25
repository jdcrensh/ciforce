git    = require './src/git'
sfdc   = require './src/sfdc'
gulp   = require 'gulp'
del    = require 'del'

gulp.task 'default', ['git:repo']

### clean task ###
gulp.task 'clean:pkg', -> del.sync 'pkg/**'
gulp.task 'clean:repo', -> del.sync 'repo/**'
gulp.task 'clean', ['clean:pkg', 'clean:repo']

### git tasks ###
gulp.task 'git:repo', git.repo
gulp.task 'git:pkg', ['clean:pkg', 'git:repo', 'sfdc:describeMetadata'], git.pkg

### sfdc tasks ###
gulp.task 'sfdc:login', sfdc.login
gulp.task 'sfdc:describeMetadata', ['sfdc:login'], sfdc.describeMetadata
gulp.task 'sfdc:describeGlobal', ['sfdc:login'], sfdc.describeGlobal
gulp.task 'sfdc:listMetadata', ['sfdc:login', 'sfdc:describeMetadata'], sfdc.listMetadata
gulp.task 'sfdc:validate', ['git:pkg'], sfdc.validate
gulp.task 'sfdc:retrieve', ['sfdc:login'], sfdc.retrieve
