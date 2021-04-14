docker-compose build
docker-compose up -d
sleep 10
./register_cluster.sh 
sleep 5
docker exec -it -u lab slurmctld bash
