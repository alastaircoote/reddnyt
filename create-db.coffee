sqlite3 = require('sqlite3').verbose()
Promise = require 'bluebird'
path = require 'path'
fs = Promise.promisifyAll require 'fs'

db = new sqlite3.Database path.join(__dirname,'newswire.db')

fs.readFileAsync path.join(__dirname,'db.sql'), 'UTF-8'
.then (sql) ->
    db.serialize ->
        db.run 'DROP TABLE IF EXISTS "newswire";'
        db.run sql
        db.close()