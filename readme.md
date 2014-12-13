reddnyt
=======

Taking social share data from Twitter and Facebook, and applying the Reddit algorithm to it.

It runs once per minute (to grab new articles), updating each article's share counts every
five minutes.

Requirements
------------

- Node.js
- An S3 bucket (with AWS key access)

Installation
------------

- Clone this git repo. Run ```npm install``` to install dependencies.
- Copy ```config.example.json``` to ```config.json``` and switch out the values for
  your own.
- Run ```npm create-db``` to create the sqlite database.
- Run ```npm start``` to start the crawler.