var fs = require('fs-extra');
var express = require('express');
var app = express();
var bodyParser = require('body-parser');
var session = require('express-session');

var publicDir = __dirname + '/public';

var floors = {};
var passes = {
  admin01: 'admin01',
  user01 : 'user01'
};
var users = {
  admin01: { id:'admin01', org: 'Sample Co.,Ltd', name: 'Admin01', mail: 'admin01@xxx.com', role: 'admin' },
  user01 : { id:'user01', org: 'Sample Co.,Ltd', name: 'User01', mail: 'user01@xxx.com', role: 'general' }
};

app.use(bodyParser.json());
app.use(bodyParser.urlencoded({ extended: false }));
app.use(session({
  secret: 'keyboard cat',
  resave: false,
  saveUninitialized: false,
  cookie: {
    maxAge: 30 * 60 * 1000
  }
}));


/* Login NOT required */
app.post('/api/v1/login', function(req, res) {
  var id = req.body.id;
  var pass = req.body.pass;
  if(passes[id] === pass) {
    req.session.user = id;
    res.send({});
  } else {
    res.status(401).send('');
  }
});

app.post('/api/v1/logout', function(req, res) {
  req.session.user = null;
  res.send({});
});

app.use(express.static(publicDir));

// Login
// app.use('/', function(req, res, next) {
//   if(!req.session.user && req.url.indexOf('/api') === 0) {
//     res.status(401).send('');
//   } else {
//     next();
//   }
// });

function role(req) {
  if(!req.session.user) {
    return "guest"
  } else {
    return req.session.user.role;
  }
}


/* Login required */

app.get('/login', function(req, res) {
  res.sendfile(publicDir + '/login.html');
});

app.get('/logout', function(req, res) {
  req.session.user = null;
  res.redirect('/login');
});

app.get('/api/v1/auth', function(req, res) {
  var id = req.session.user;
  if(id) {
    var user = users[id];
    res.send(user);
  } else {
    res.send({});
  }
});
app.get('/api/v1/floors', function (req, res) {
  var floors_ = Object.keys(floors).map(function(id) {
    return floors[id];
  });
  res.send(floors_);
});
app.get('/api/v1/search/:query', function (req, res) {
  var query = req.params.query;
  var floors_ = Object.keys(floors).map(function(id) {
    return floors[id];
  });
  var results = floors_.reduce(function(memo, floor) {
    return floor.equipments.reduce(function(memo, e) {
      if(e.name.indexOf(query) >= 0) {
        return memo.concat([[e, floor.id]]);
      } else {
        return memo;
      }
    }, memo);
  }, []);
  res.send(results);
});
app.get('/api/v1/candidate/:name', function (req, res) {
  var name = req.params.name;
  var users_ = Object.keys(users).map(function(id) {
    return users[id];
  });
  var results = users_.reduce(function(memo, user) {
    if(user.name.toLowerCase().indexOf(name.toLowerCase()) >= 0) {
      return memo.concat([user.id]);
    } else {
      return memo;
    }
  }, []);
  res.send(results);
});
app.get('/api/v1/floor/:id/edit', function (req, res) {
  var id = req.params.id;
  var floor = floors[id];
  console.log('get: ' + id);
  // console.log(floor);
  if(floor) {
    res.send(floor);
  } else {
    res.status(404).send('not found by id: ' + id);
  }
});

app.put('/api/v1/floor/:id/edit', function (req, res) {
  // if(role(req) !== 'admin') {
  //   res.status(401).send('');
  //   return;
  // }
  var id = req.params.id;
  var newFloor = req.body;
  if(id !== newFloor.id) {
    throw "invalid!";
  }
  floors[id] = newFloor;
  console.log('saved floor: ' + id);
  // console.log(newFloor);
  res.send('');
});

// publish
app.post('/api/v1/floor/:id', function (req, res) {
  if(role(req) !== 'admin') {
    res.status(401).send('');
    return;
  }
  var id = req.params.id;
  var newFloor = req.body;
  console.log(req.body);
  if(id !== newFloor.id) {
    throw "invalid! : " + [id, newFloor.id];
  }
  floors[id] = newFloor;
  console.log('published floor: ' + id);
  // console.log(newFloor);
  res.send('');
});


app.put('/api/v1/image/:id', function (req, res) {
  if(role(req) !== 'admin') {
    res.status(401).send('');
    return;
  }
  var id = req.params.id;
  console.log(id);
  var all = [];
  req.on('data', function(data) {
    all.push(data);
  });
  req.on('end', function() {
    var image = Buffer.concat(all);
    fs.writeFile(publicDir + '/images/' + id, image, function(e) {
      if(e) {
        res.status(500).send('' + e);
      } else {
        res.end();
      }
    });
  })
});

fs.emptyDirSync(publicDir + '/images');
app.listen(3000, function () {
  console.log('mock server listening on port 3000.');
});
