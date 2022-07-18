dkjson = require "dkjson"
redis = require "resty.redis"

druid_polymorph = require "druid_polymorph"
druid_polymorph.init({
  lookups = {
-- shop_id = "shop_id"
  },
  redis = {
    host = "127.0.0.1",
    port = 6379
  }
})
-- uncomment to activate debug mode
-- druid_polymorph.setDebugModeOn()
