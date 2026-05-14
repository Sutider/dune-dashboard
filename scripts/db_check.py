import sys, psycopg2
try:
    c = psycopg2.connect(host='localhost', port=int(sys.argv[1]), user='postgres', password='postgres', dbname='dune', connect_timeout=3)
    c.close()
    print('ok')
except:
    pass