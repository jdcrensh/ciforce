import path from 'path';
import _ from 'lodash';

// extend path module with additional utility
_.extend(path, {
  // split into array of path segments
  split(p) {
    return p.split(path.sep);
  },

  // add to end of path and return the new path
  push(p, ...segments) {
    if (!_.isString(p)) {
      throw new TypeError(`Argument must be a string, not ${typeof p}`);
    }
    segments.forEach((segment, i) => {
      if (!_.isString(segment)) {
        throw new TypeError(`Argument at index ${i} must be a string or undefined, not ${typeof segment}`);
      }
    });
    const arr = path.split(p);
    arr.push(...segments);
    return path.join(...arr);
  },

  // remove last path element, returning it and the new path
  pop(p) {
    if (!_.isString(p)) {
      throw new TypeError(`Argument must be a string, not ${typeof p}`);
    }
    const arr = path.split(p);
    return [arr.pop(), path.join(...arr)];
  },

  // insert before first path element and return the new path
  unshift(p, ...segments) {
    if (!_.isString(p)) {
      throw new TypeError(`Argument must be a string, not ${typeof p}`);
    }
    segments.forEach((segment, i) => {
      if (!_.isString(segment)) {
        throw new TypeError(`Argument at index ${i} must be a string or undefined, not ${typeof segment}`);
      }
    });
    const arr = path.split(p);
    arr.unshift(...segments);
    return path.join(...arr);
  },

  // remove first path element, returning it and the new path
  shift(p) {
    if (!_.isString(p)) {
      throw new TypeError(`'p' must be a string, not ${typeof p}`);
    }
    const arr = path.split(p);
    return [arr.shift(), path.join(...arr)];
  },
});
