var request = require('request');
var log = require('./log.js');

function send(token, method, url, data) {
  log.system.debug(method, url);
  return new Promise((resolve, reject) => {
    var options = {
      method: method,
      url: url,
      headers: {
        'Authorization': 'JWT ' + token
      },
      body: data,
      json: true
    };
    request(options, function(e, response, body) {
      if (e || response.statusCode >= 400) {
        log.system.error(response.statusCode, 'account service: failed ' + method + ' ' + url);
        log.system.error(body.message);
        reject(body.message ? body : e || response.statusCode);
      } else {
        resolve(body);
      }
    });
  });
}

function get(token, url) {
  return send(token, 'GET', url);
}

function post(token, url, data) {
  return send(token, 'POST', url, data);
}

function login(root, userId, password) {
  return post('', root + '/1/authentication', {
    userId: userId,
    password: password
  }).then(obj => {
    return obj.accessToken;
  });
}

function addUser(root, token, user) {
  user.userId = user.id;
  user.password = user.pass;
  user.role = user.role.toUpperCase();
  return post(token, root + '/1/users', user);
}

module.exports = {
  addUser: addUser,
  login: login
};
