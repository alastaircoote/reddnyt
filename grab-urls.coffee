Promise = require 'bluebird'
requestAsync = Promise.promisify require 'request'

sqlite3 = require 'sqlite3'
path = require 'path'
fs = require 'fs'
AWS = require 'aws-sdk'
zlib = Promise.promisifyAll require('zlib')

if !fs.existsSync './config.json'
    throw new Error "No configuration file created."

if !fs.existsSync "./newswire.db"
    throw new Error "No database. Run npm create-db to create it."

Config = require './config'

AWS.config.update
    accessKeyId: Config['aws-key']
    secretAccessKey: Config['aws-secret']

s3Client = Promise.promisifyAll new AWS.S3()

db = Promise.promisifyAll new sqlite3.Database path.join(__dirname,'newswire.db')

refreshEvery = 5 * 60 * 1000 # Refresh every 5 mins
twodays = 1000 * 60 * 60 * 24 * 2 # Keep it to the last two days so that we don't totally spam the API endpoints.

arrayIntoArrays = (arr, numberPerArray) ->
    retArray = []
    arrCopy = arr.slice(0)
    while arrCopy.length > 0
        retArray.push arrCopy.splice 0, 50
    return retArray
    
getNewURLs = (offset) ->
    offset = offset or 0
    requestAsync
        url: "http://api.nytimes.com/svc/news/v3/content/all/all/48.json?offset=#{offset}&api-key=" + Config['timeswire-api-key']
        json: true
    .then ([res,json]) ->
        if !json.results

            # Something failed in the API call. For the sake of this hack we won't investigate it
            # properly, but in a better system we would.

            throw new Error json
        urls = json.results.map (r) -> r.url

        # Directly putting a string into the query like this is unsafe, but as far as I am aware there is no
        # ability to pass an array as an argument with sqlite3-node. Again, it's a hack. No rules!

        db.allAsync "SELECT url FROM newswire WHERE url in ('" + urls.join("','") + "')"
        .then (rows) ->

            existingUrls = rows.map (r) -> r.url

            # Extract only stories we don't already have in the database.
            newRows = json.results.filter (r) -> existingUrls.indexOf(r.url) == -1

            Promise.each newRows, (r) ->
                largeThumb = null
               
                if r.multimedia
                    largeThumb = r.multimedia.filter((f) -> f.format == 'thumbLarge')[0]?.url

                db.runAsync """
                    INSERT INTO newswire (url,date_created,fb_shares,tw_shares, photo, title, last_updated)
                    VALUES($1,$2,0,0,$3,$4, NULL)
                """,
                [r.url,Date.parse(r.created_date), largeThumb, r.title]

            .then ->
                if newRows.length < rows.length or offset + json.results.length >= json.num_results
                    # We've fetched all the new URLs, so we can close our the promise loop.
                    return true
                else
                    # We still have more new URLs - up the offset and run again.
                    Promise.delay(200)
                    .then -> getNewURLs offset + 20

updateData = ->

    # Start by tidying up the database, remove entries we don't want to use any more.
    db.runAsync """
        DELETE FROM newswire WHERE date_created < $1
    """, [Date.now() - twodays]
    .then ->
        getNewURLs()
    .then ->
        db.allAsync """
            SELECT url FROM newswire WHERE last_updated IS NULL OR last_updated < $1
        """, [Date.now() - refreshEvery]
    .then (rows) ->
        console.log "Updating #{rows.length} rows..."
        shareData = rows.map (r) ->
            return {
                url: r.url
                fb_shares: null
                tw_shares: null
            }

        batch50Urls = arrayIntoArrays(shareData, 50)
       
        Promise.all [
            
            # The Facebook Graph API lets us batch request. So we'll group them into
            # arrays of 50 items.

            Promise.each batch50Urls, (arr) ->
                requestAsync
                    url: "http://graph.facebook.com?ids=" + arr.map((u) -> u.url).join(',')
                    json:true
                .then ([res,fbData]) ->
                    for entry in arr
                        entry.fb_shares = Number(fbData[entry.url].shares)


            # No such luck with the Twitter endpoint. We throttle our requests to it in order to not
            # spam it too much.

            Promise.each shareData, (entry) ->
                requestAsync
                    url: "https://cdn.api.twitter.com/1/urls/count.json?url=" + encodeURIComponent(entry.url)
                    json: true

                # Sometimes the Twitter endpoint freezes and doesn't return, so we enforce a timeout

                .timeout(1000)
                .then ([res,json]) ->
                    entry.tw_shares = Number(json.count)

                    # Wait, so that we don't spam Twitter's endpoint.

                    return Promise.delay(200)
                .catch (err) ->
                    console.log "Twitter API request for #{entry.url} timed out."
                
            , {concurrency: 1} # Don't hit the API endpoint multiple times at once
        ]
        .then ->
            Promise.each shareData, (entry) ->
                db.runAsync """
                    UPDATE newswire SET fb_shares = $1, tw_shares = $2, last_updated = $3 WHERE url = $4
                """, [entry.fb_shares, entry.tw_shares, Date.now(), entry.url]

    .then ->
        db.allAsync "SELECT * FROM newswire"
    .then (rows) ->
        rows.forEach (row) ->

            # This is a rough translation of the Reddit algorithm described here:
            # http://amix.dk/blog/post/19588

            totalShares = row.fb_shares + row.tw_shares
            order = Math.log(Math.max(totalShares,1)) / 2.302585092994046
            sign = if totalShares > 0 then 1 else 0

            seconds = Math.round (row.date_created - new Date(2014,10,16)) / 1000

            points = (order + sign * seconds / 45000) * 7
            row.points = Math.round(points) / 7

        rows = rows.sort (a,b) ->
            return b.points - a.points


        resultJSON = JSON.stringify(rows,null,2)
        jsonPWrapper = "callback(" + resultJSON + ")"
        #console.log resultJSON
        zlib.gzipAsync(jsonPWrapper)
    .then (gzipped) ->
        s3Client.putObjectAsync
            Bucket: Config['s3-bucket']
            Key: Config['s3-upload-path']
            Body: gzipped
            ContentType: 'text/javascript; charset=utf-8'
            ACL: 'public-read'
            ContentEncoding: 'gzip'

    .then ->
        console.log "Uploaded latest."

        setTimeout updateData, 1000 * 60

updateData()

