import mysql.connector
import redis

entities = {
	"shop_id"
}

sharding_value = 100000

cnx = mysql.connector.connect(user='<user>', password='<password>', host='localhost', database='mydb')
r = redis.Redis(host='localhost', port=6379, db=0)

for entity in entities:
	cur = cnx.cursor()
	if entity == "shop_id":
		cur.execute("SELECT shop.id, shop.country, shop.city, shop.name FROM shop")
		for (id, country, city, name) in cur:
			r.hset("{}.{}".format(entity, str(int(id/sharding_value))), id, "{} - {} ({}, {})".format(str(id), name, city, country))
		cur.close()
cnx.close()
