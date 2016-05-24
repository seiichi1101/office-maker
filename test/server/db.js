var url = require('url');
var fs = require('fs-extra');
var _async = require('async');

var sql = require('./sql.js');
var rdb = require('./rdb2.js');
var schema = require('./schema.js');
var filestorage = require('./filestorage.js');
var mock = require('./mock.js');

function saveEquipments(floorId, floorVersion, equipments, cb) {
  var sqls = equipments.map(function(equipment) {
    return sql.insert('equipments', schema.equipmentKeyValues(floorId, floorVersion, equipment));
  });
  sqls.unshift(sql.delete('equipments', sql.whereList([['floorId', floorId], ['floorVersion', floorVersion]])));
  rdb.batch(sqls, cb);
}
function getEquipments(floorId, floorVersion, cb) {
  var q = sql.select('equipments', sql.whereList([['floorId', floorId], ['floorVersion', floorVersion]]));
  rdb.exec(q, cb);
}
function getFloorWithEquipments(withPrivate, id, cb) {
  getFloor(withPrivate, id, function(e, floor) {
    if(e) {
      cb(e);
    } else if(!floor) {
      cb(null, null);
    } else {
      getEquipments(floor.id, floor.version, function(e, equipments) {
        if(e) {
          cb(e);
        } else {
          floor.equipments = equipments;
          cb(null, floor);
        }
      });
    }
  });
}
function getFloor(withPrivate, id, cb) {
  var q = sql.select('floors', sql.where('id', id))
  rdb.exec(q, function(e, floors) {

    if(e) {
      cb(e);
    } else {
      var _floor = null;
      floors.forEach(function(floor) {
        if(!_floor || _floor.version < floor.version) {
          if(floor.public || withPrivate) {
            _floor = floor;
          }
        }
      });
      cb(null, _floor);
    }
  });
}
function getFloors(withPrivate, cb) {
  rdb.exec(sql.select('floors'), function(e, floors) {
    if(e) {
      cb(e);
    } else {
      var results = {};
      floors.forEach(function(floor) {
        if(!results[floor.id] || results[floor.id].version < floor.version) {
          if(floor.public || withPrivate) {
            results[floor.id] = floor;
          }
        }
      });
      var ret = Object.keys(results).map(function(id) {
        return results[id];
      });
      cb(null, ret);
    }
  });
}
function getFloorsWithEquipments(withPrivate, cb) {
  getFloors(withPrivate, function(e, floors) {
    if(e) {
      cb(e);
    } else {
      var functions = floors.map(function(floor) {
        return function(cb) {
          return getEquipments(floor.id, floor.version, cb);
        };
      });
      _async.parallel(functions, function(e, equipmentsList) {
        if(e) {
          cb(e);
        } else {
          equipmentsList.forEach(function(equipments, i) {
            floors[i].equipments = equipments;//TODO don't mutate
          });
          cb(null, floors);
        }
      });
    }
  });
}
function ensureFloor(id, cb) {
  cb && cb();
}
function saveFloorWithEquipments(newFloor, cb) {
  if(!newFloor.equipments) {
    throw "invalid: ";
  }
  getFloor(true, newFloor.id, function(e, floor) {
    if(e) {
      cb && cb(e);
    } else {
      newFloor.version = newFloor.version || 0;// TODO
      var sqls = [
        sql.delete('floors', sql.where('id', newFloor.id) + ' and public=false'),
        sql.insert('floors', schema.floorKeyValues(newFloor))
      ];
      rdb.batch(sqls, function(e) {
        if(e) {
          cb && cb(e);
        } else {
          saveEquipments(newFloor.id, newFloor.version, newFloor.equipments, cb);
        }
      });
    }
  });
}

function publishFloor(newFloor, cb) {
  newFloor.version = newFloor.version || 0;
  newFloor.version = newFloor.version + 1;
  saveFloorWithEquipments(newFloor, cb);
}

function saveUser(user, cb) {
  rdb.batch([
    sql.delete('users', sql.where('id', user.id)),
    sql.insert('users', schema.userKeyValues(user))
  ], cb);
}

function savePerson(person, cb) {
  rdb.batch([
    sql.delete('people', sql.where('id', person.id)),
    sql.insert('people', schema.personKeyValues(person))
  ], cb);
}

function saveImage(path, image, cb) {
  filestorage.save(path, image, cb);
}
function resetImage(dir, cb) {
  filestorage.empty(dir, cb);
}
function getCandidate(name, cb) {
  // TODO like search
  getPeople(function(e, people) {
    if(e) {
      cb(e);
    } else {
      var results = people.reduce(function(memo, person) {
        if(person.name.toLowerCase().indexOf(name.toLowerCase()) >= 0) {
          return memo.concat([person]);
        } else {
          return memo;
        }
      }, []);
      cb(null, results);
    }
  });
}
function search(query, all, cb) {
  getFloorsWithEquipments(all, function(e, floors) {
    if(e) {
      cb(e);
    } else {
      var results = floors.reduce(function(memo, floor) {
        return floor.equipments.reduce(function(memo, e) {
          if(e.name.indexOf(query) >= 0) {
            return memo.concat([[e, floor.id]]);
          } else {
            return memo;
          }
        }, memo);
      }, []);
      cb(null, results);
    }
  });
}
function getPrototypes(cb) {
  rdb.exec(sql.select('prototypes'), function(e, prototypes) {
    cb(null, prototypes);
  });
}
function savePrototypes(newPrototypes, cb) {
  var inserts = newPrototypes.map(function(proto) {
    return sql.insert('prototypes', schema.prototypeKeyValues(proto));
  });
  inserts.unshift(sql.delete('prototypes'));
  rdb.batch(inserts, cb);
}
function getUser(id, cb) {
  rdb.exec(sql.select('users', sql.where('id', id)), function(e, users) {
    if(e) {
      cb(e);
    } else if(users.length < 1) {
      cb(null, null);
    } else {
      cb(null, users[0]);
    }
  });
}
function getUserWithPerson(id, cb) {
  getUser(id, function(e, user) {
    if(e) {
      cb(e);
    } else if(!user) {
      cb(null, null);
    } else {
      getPerson(user.personId, function(e, person) {
        if(e) {
          cb(e);
        } else {
          user.person = person;//TODO don't mutate
          cb(null, user);
        }
      });
    }
  });
}
function getPeople(cb) {
  rdb.exec(sql.select('people'), cb);
}
function getPerson(id, cb) {
  rdb.exec(sql.select('people', sql.where('id', id)), function(e, people) {
    if(e) {
      cb(e);
    } else if(people.length < 1) {
      cb(null, null);
    } else {
      cb(null, people[0]);
    }
  });
}
function getColors(cb) {
  rdb.exec(sql.select('colors', sql.where('id', '1')), function(e, colors) {
    if(e) {
      cb(e);
    } else {
      var _colors = [];
      [1,2,3,4,5,6,7,8,9,10].forEach(function(i) {
        var c = colors[0]['color' + i];
        if(c) {
          _colors.push(c);
        }
      });
      cb(null, _colors);
    }
  });
}
function saveColors(newColors, cb) {
  var keyValues = newColors.map(function(c, index) {
    return ['color' + index, c];
  });
  keyValues.unshift(['id', '1']);
  rdb.batch([
    sql.delete('colors'),
    sql.insert('colors', keyValues)
  ], cb);
}

function init(cb) {
  _async.series(mock.users.map(function(user) {
    return saveUser.bind(null, user);
  }).concat(mock.people.map(function(person) {
    return savePerson.bind(null, person);
  })).concat([
    savePrototypes.bind(null, mock.prototypes)
  ]).concat([
    saveColors.bind(null, mock.colors)
  ]), cb);
}
init(function(e) {
  if(e) {
    console.log(e);
  }
});//TODO export

module.exports = {
  getUser: getUser,
  getUserWithPerson: getUserWithPerson,
  getPerson: getPerson,
  getCandidate: getCandidate,
  search: search,
  getPrototypes: getPrototypes,
  savePrototypes: savePrototypes,
  getColors: getColors,
  saveColors: saveColors,
  getFloorWithEquipments: getFloorWithEquipments,
  getFloorsWithEquipments: getFloorsWithEquipments,
  ensureFloor: ensureFloor,
  saveFloorWithEquipments: saveFloorWithEquipments,
  publishFloor: publishFloor,
  saveImage: saveImage,
  resetImage: resetImage
};