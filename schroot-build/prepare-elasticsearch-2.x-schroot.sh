#!/bin/sh

CONTAINER=$1

cat > $CONTAINER/root/install <<EOF
#!/bin/sh
#
# install elasticsearch 2.x
#
aptitude update && aptitude -y full-upgrade && aptitude -y install wget && {
  wget -qO - https://packages.elastic.co/GPG-KEY-elasticsearch | apt-key add -
  echo 'deb http://packages.elastic.co/elasticsearch/2.x/debian stable main' > /etc/apt/sources.list.d/elasticsearch-2.x.list
  echo 'deb http://ppa.launchpad.net/webupd8team/java/ubuntu precise main' > /etc/apt/sources.list.d/webupd8team-java.list
  apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys EEA14886
  aptitude update && {
    echo 'oracle-java8-installer shared/accepted-oracle-license-v1-1 select true' | /usr/bin/debconf-set-selections
    aptitude -y install procps oracle-java8-installer oracle-java8-set-default elasticsearch && {
      rm /var/cache/oracle-jdk8-installer/*.tar.gz
      /usr/share/elasticsearch/bin/plugin install lmenezes/elasticsearch-kopf
      /usr/share/elasticsearch/bin/plugin install royrusso/elasticsearch-HQ
      /usr/share/elasticsearch/bin/plugin install mobz/elasticsearch-head
      adduser --system --no-create-home --group \
              --disabled-password --disabled-login \
              --shell /usr/sbin/nologin elasticsearch
      update-rc.d elasticsearch defaults 95 10
    }
  }
}
EOF

cat > $CONTAINER/root/init <<EOF
#!/bin/sh

/etc/init.d/elasticsearch start
EOF
