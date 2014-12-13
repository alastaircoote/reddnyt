CREATE TABLE "newswire" (
     "url" TEXT NOT NULL,
     "fb_shares" integer,
     "tw_shares" integer,
     "date_created" integer,
     "last_updated" integer,
     "photo" TEXT,
     "title" TEXT,
    PRIMARY KEY("url")
);