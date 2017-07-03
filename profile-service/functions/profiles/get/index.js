var AWS = require('aws-sdk');
var jwt = require('jsonwebtoken');
var documentClient = new AWS.DynamoDB.DocumentClient();
var common = require('common');

exports.handler = common.authorized((event, context, user, callback) => {
  documentClient.get({
    TableName: "profiles",
    Key: {
      userId: event.pathParameters.userId
    }
  }, function(e, data) {
    if (e) {
      callback(e);
      return;
    }
    var profile = data.Item;
    if (!profile) {
      callback(null, {
        statusCode: 404,
        headers: {
          "Content-Type": "application/json"
        },
        body: ''
      });
    } else {
      callback(null, {
        statusCode: 200,
        headers: {
          "Content-Type": "application/json"
        },
        body: JSON.stringify(profile)
      });
    }

  });
});
