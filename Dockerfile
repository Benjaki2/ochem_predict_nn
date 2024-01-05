# Download the reaction databases
FROM crazymax/7zip as data-downloader
RUN mkdir -p /data
RUN wget https://ndownloader.figshare.com/files/8023418 --directory-prefix=/data
RUN mv /data/8023418 /data/dump.7z
WORKDIR /data
RUN 7z x dump.7z
RUN rm -rf /data/dump.7z

# Inject them into the database
FROM mongo:3.7.3-jessie as mongo-db-ingester

COPY --from=data-downloader /data/dump /dump

RUN mkdir -p /data/db-chem
RUN mongod --fork --dbpath /data/db-chem --logpath /var/log/mongodb.log && mongorestore /dump
# Validate
RUN mongod --fork --dbpath /data/db-chem --logpath /var/log/mongodb.log && mongo --eval "new Mongo().adminCommand('listDatabases')"


# Now build the main docker image
# with all chemistry dependencies, mongo database, and mongo database data
FROM continuumio/anaconda:5.0.1

####################################
# Dependencies
RUN echo "deb http://archive.debian.org/debian stretch main contrib non-free" > /etc/apt/sources.list
RUN apt-get update

RUN apt-get install -y python-h5py
RUN conda install -y tensorflow
RUN conda install -y pymongo
RUN conda install -y theano
RUN conda install -y tqdm
RUN conda install -y keras
ENV KERAS_BACKEND=theano

####################################
# Custom RDKIT
RUN apt-get update
RUN apt-get install -y build-essential python-numpy cmake python-dev sqlite3 libsqlite3-dev libboost-dev libboost-system-dev libboost-thread-dev libboost-serialization-dev libboost-python-dev libboost-regex-dev

ENV RDKIT_BRANCH=dionjwa-patch-1
RUN git clone -b $RDKIT_BRANCH --single-branch https://github.com/dionjwa/rdkit.git

ENV RDBASE=/rdkit
ENV LD_LIBRARY_PATH=$LD_LIBRARY_PATH:$RDBASE/lib:/usr/lib/x86_64-linux-gnu
ENV PYTHONPATH=$PYTHONPATH:$RDBASE

RUN mkdir $RDBASE/build
WORKDIR $RDBASE/build

RUN cmake -DRDK_BUILD_INCHI_SUPPORT=ON .. &&\
 make &&\
 make install &&\
 make clean
####################################

####################################
# Install mongodb locally, and grab the data

# add our user and group first to make sure their IDs get assigned consistently, regardless of whatever dependencies get added
RUN groupadd -r mongodb && useradd -r -g mongodb mongodb

RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		ca-certificates \
		jq \
		numactl \
	&& rm -rf /var/lib/apt/lists/*

# grab gosu for easy step-down from root (https://github.com/tianon/gosu/releases)
ENV GOSU_VERSION 1.10
# grab "js-yaml" for parsing mongod's YAML config files (https://github.com/nodeca/js-yaml/releases)
ENV JSYAML_VERSION 3.10.0

RUN set -ex; \
	\
	apt-get update; \
	apt-get install -y --no-install-recommends \
		wget \
	; \
	rm -rf /var/lib/apt/lists/*; \
	\
	dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"; \
	wget -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch"; \
	wget -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch.asc"; \
	export GNUPGHOME="$(mktemp -d)"; \
	gpg --keyserver ha.pool.sks-keyservers.net --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4; \
	gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu; \
	rm -r "$GNUPGHOME" /usr/local/bin/gosu.asc; \
	chmod +x /usr/local/bin/gosu; \
	gosu nobody true; \
	\
	wget -O /js-yaml.js "https://github.com/nodeca/js-yaml/raw/${JSYAML_VERSION}/dist/js-yaml.js"; \
# TODO some sort of download verification here
	\
	apt-get purge -y --auto-remove wget

RUN mkdir /docker-entrypoint-initdb.d

ENV GPG_KEYS \
# pub   rsa4096 2017-11-15 [SC] [expires: 2019-11-15]
#       BD8C 80D9 C729 D005 24E0  68E0 3DAB 7171 3396 F72B
# uid           [ unknown] MongoDB 3.8 Release Signing Key <packaging@mongodb.com>
	BD8C80D9C729D00524E068E03DAB71713396F72B
# https://docs.mongodb.com/manual/tutorial/verify-mongodb-packages/#download-then-import-the-key-file
RUN set -ex; \
	export GNUPGHOME="$(mktemp -d)"; \
	for key in $GPG_KEYS; do \
		gpg --keyserver ha.pool.sks-keyservers.net --recv-keys "$key"; \
	done; \
	gpg --export $GPG_KEYS > /etc/apt/trusted.gpg.d/mongodb.gpg; \
	rm -r "$GNUPGHOME"; \
	apt-key list

# Allow build-time overrides (eg. to build image with MongoDB Enterprise version)
# Options for MONGO_PACKAGE: mongodb-org OR mongodb-enterprise
# Options for MONGO_REPO: repo.mongodb.org OR repo.mongodb.com
# Example: docker build --build-arg MONGO_PACKAGE=mongodb-enterprise --build-arg MONGO_REPO=repo.mongodb.com .
ARG MONGO_PACKAGE=mongodb-org-unstable
ARG MONGO_REPO=repo.mongodb.org
ENV MONGO_PACKAGE=${MONGO_PACKAGE} MONGO_REPO=${MONGO_REPO}

ENV MONGO_MAJOR 3.7
ENV MONGO_VERSION 3.7.3

RUN echo "deb http://$MONGO_REPO/apt/debian jessie/${MONGO_PACKAGE%-unstable}/$MONGO_MAJOR main" | tee "/etc/apt/sources.list.d/${MONGO_PACKAGE%-unstable}.list"

RUN set -x \
	&& apt-get update \
	&& apt-get install -y \
		${MONGO_PACKAGE}=$MONGO_VERSION \
		${MONGO_PACKAGE}-server=$MONGO_VERSION \
		${MONGO_PACKAGE}-shell=$MONGO_VERSION \
		${MONGO_PACKAGE}-mongos=$MONGO_VERSION \
		${MONGO_PACKAGE}-tools=$MONGO_VERSION \
	&& rm -rf /var/lib/apt/lists/* \
	&& rm -rf /var/lib/mongodb \
	&& mv /etc/mongod.conf /etc/mongod.conf.orig

# Copy the data added previously
COPY --from=mongo-db-ingester /data/db-chem /data/db-chem
COPY --from=mongo-db-ingester /data/configdb /data/configdb

RUN chown -R mongodb:mongodb /data/db-chem /data/configdb

# Optionally validate
# RUN mongod --fork --dbpath /data/db-chem --logpath /var/log/mongodb.log && mongo --eval "new Mongo().adminCommand('listDatabases')"

# End mongo install
####################################

# Paper source code
COPY . /chem/ochem_predict_nn
# RUN chmod 755 /chem/ochem_predict_nn/run.sh

ENTRYPOINT ["/chem/ochem_predict_nn/run.sh"]

# Ugly workaround since the main user is mongodb now. Whatever, it's a docker container.
# RUN chown -R mongodb:mongodb /chem/

# I don't remember if this is needed
ENV MKL_THREADING_LAYER=GNU

# Update paths
ENV PYTHONPATH=$PYTHONPATH:/chem:.:..:/chem/ochem_predict_nn:/rdkit/External/INCHI-API/python

