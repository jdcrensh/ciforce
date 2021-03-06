import gulp from 'gulp';
import del from 'del';
import git from './src/git';
import sfdc from './src/sfdc';

gulp.task('default', ['git:repo']);

/* clean task */
gulp.task('clean:pkg', () => del.sync('pkg/**'));
gulp.task('clean:repo', () => del.sync('repo/**'));
gulp.task('clean', ['clean:pkg', 'clean:repo']);

/* git tasks */
gulp.task('git:repo', git.repo);
gulp.task('git:pkg', ['clean:pkg', 'git:repo', 'sfdc:listMetadata'], git.pkg);

/* sfdc tasks */
gulp.task('sfdc:login', sfdc.login);
gulp.task('sfdc:describeMetadata', ['sfdc:login'], sfdc.describeMetadata);
gulp.task('sfdc:describeGlobal', ['sfdc:login'], sfdc.describeGlobal);
gulp.task('sfdc:listMetadata', ['sfdc:describeMetadata'], sfdc.listMetadata);
gulp.task('sfdc:excludeManaged', ['git:pkg'], sfdc.excludeManaged);
gulp.task('sfdc:removeExcludes', ['sfdc:excludeManaged'], sfdc.removeExcludes);
gulp.task('sfdc:pkg', ['sfdc:removeExcludes']);
gulp.task('sfdc:validate', ['sfdc:pkg'], sfdc.validate);
gulp.task('sfdc:retrieve', ['sfdc:login'], sfdc.retrieve);
