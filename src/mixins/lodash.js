import _ from 'lodash';

_.mixin({
  mapPlucked(obj, name) {
    return _.mapValues(obj, _.partial(_.pluck, _, name));
  },
  compactArray(value) {
    return _.compact(_.flatten([value]));
  },
  mapProperty(value, prop) {
    return _.map(value, _.property(prop));
  },
});
