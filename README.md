# Druid Polymorph

Druid Polymorph is a LUA module for NGINX OpenResty used to emulate [Druid Lookups](https://druid.apache.org/docs/latest/querying/lookups.html) behavior for use-cases with a very large number of values to be cached.


# Installation



## Requirements

* [OpenResty](https://openresty.org/en/download.html) with LUA support enabled
* Redis server


## Steps


### Install dependencies

Install OpenResty with the method you prefer. Ensure LUA support is enabled and the Resty Redis package is available (should be default in recent verison of OpenResty).

Install Redis Server.

### Install Druid Polymorph LUA module and nginx configurations

All required files are in the *nginx/* subfolder. Copy the content of that folder to your installation of NGINX replacing or modifying manually as required

From the root of the repository
```
cp -r nginx/* /etc/nginx/
```

Activate the virtualhost by doing 
```
ln -s /etc/nginx/sites-available/druid_polymorph_vhost /etc/nginx/sites-enabled/
```

## Adding your lookups

In the current stage, all the necessary modules/configurations are installed but there is no lookups configured nor there is any data. This part will demonstrate an example to generate lookups data and use them in the proxy

### Configure the lookup dimension

We are going to take as example a simple usage - imagining a data schema in Druid where you actually store an ID in numerical format and you'd like to make it clearer in Pivot by showing the name alongside the ID.

Let's take Shop ID as *shop_id* as an example:
* Add this *shop_id* to the *lookups* LUA dict in init_worker.lua as following:

```
pivot_proxy.init({
lookups = {
shop_id = "shop_id"
}
})
```

* Add the *shop_id* shared LUA dictionnary to the */etc/nginx/druid_polymorph_shared_dict* file (size can be modified to suit your needs - the larger the dict, the slower the initialization) as following:

```
lua_shared_dict shop_id 100m;
```

### Generate the lookup values

Lookups are expected to be stored in a Redis HASH. You can generate this hash as you see fit, by default, Druid Polymorph expect hashes of the following structure (for our example):

Hash: shop_id.X where X is *shop_id/100000*
Hash keys: shop_id
Hash values: lookups (always of the format of : shop_id + " " + any other strings)

For example, for the following dataset:

|shop_id|shop_name|Hash used to store the lookup|
|--|--|--|
|111111|Awesome Shop 1|shop_id.1
|123456|Awesome Shop 2|shop_id.1
|234561|Awesome Shop 3|shop_id.2
|345671|Awesome Shop 4|shop_id.3
|4444444|Awesome Shop 5|shop_id.44

Hashes would be expected to look as follow:

|hash|key|value|
|--|--|--|
|shop_id.1|111111|111111 (Awesome Shop 1)
||123456|123456 (Awesome Shop 2)
|shop_id.2|234561|234561 (Awesome Shop 3)
|shop_id.3|345671|345671 (Awesome Shop 4)
|shop_id.44|4444444|444444 (Awesome Shop 5)

You can see the simple python script in examples/ to pull values from a table in MySQL and write it to Redis.

### All done!

After loading your data in Redis and restarting NGINX, you should be all set. The module will by default reload data from Redis every 5 minutes.

