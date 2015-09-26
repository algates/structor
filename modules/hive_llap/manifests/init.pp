#  Licensed to the Apache Software Foundation (ASF) under one or more
#   contributor license agreements.  See the NOTICE file distributed with
#   this work for additional information regarding copyright ownership.
#   The ASF licenses this file to You under the Apache License, Version 2.0
#   (the "License"); you may not use this file except in compliance with
#   the License.  You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

# Note: This manifest builds everything manually and replaces the existing Hive.

class hive_llap {
  require hive_client
  require tez_client

  $INSTALL_ROOT="/usr/hdp/autobuild"
  $TEZ_BRANCH="master"
  $TEZ_VERSION="0.8.1-SNAPSHOT"
  $LLAP_BRANCH="llap"
  $HIVE_VERSION="2.0.0-SNAPSHOT"
  $PROTOBUF_VER="protobuf-2.5.0"
  $PROTOBUF_DIST="http://protobuf.googlecode.com/files/$PROTOBUF_VER.tar.bz2"

  # XXX: This path only works on Owen's base box!
  $m2_home="/usr/local/share/apache-maven-3.2.1"
  $path="/bin:/usr/bin:$INSTALL_ROOT/protoc/bin:$m2_home/bin"
  $start_script="/usr/hdp/autobuild/etc/rc.d/init.d/hive-llap"

  $hive_package="apache-hive-$HIVE_VERSION-bin"
  $target_hive="/tmp/hivesrc/packaging/target/$hive_package.tar.gz"
  $target_tez="/tmp/tezsrc/tez-dist/target/tez-$TEZ_VERSION.tar.gz"

  # Build tools I need.
  package { [ "curl", "gcc", "gcc-c++", "cmake", "git", "slider" ]:
    ensure => installed,
    before => Exec["curl -O $PROTOBUF_DIST"],
  }
  case $operatingsystem {
    'centos': {
      package { [ "zlib-devel", "openssl-devel" ]:
        ensure => installed,
        before => Exec["curl -O $PROTOBUF_DIST"],
      }
    }
    'ubuntu': {
      package { [ "zlib1g-dev", "libssl-dev" ]:
        ensure => installed,
        before => Exec["curl -O $PROTOBUF_DIST"],
      }
    }
  }

  # Add vendor repos to Maven.
  exec {"Add Vendor Repos":
    command => "sed -i~ -e '/<profiles>/r /vagrant/modules/hive_llap/files/vendor-repos.xml' settings.xml",
    cwd => "$m2_home/conf",
    path => $path,
    unless => 'grep HDPReleases settings.xml',
  }

  # Build protobuf.
  exec {"curl -O $PROTOBUF_DIST":
    cwd => "/tmp",
    path => $path,
  }
  ->
  exec {"tar -xvf $PROTOBUF_VER.tar.bz2":
    cwd => "/tmp",
    path => $path,
    creates => "/tmp/$PROTOBUF_VER",
  }
  ->
  exec {"/tmp/$PROTOBUF_VER/configure --prefix=$INSTALL_ROOT/protoc/":
    cwd => "/tmp/$PROTOBUF_VER",
    path => $path,
    creates => "/tmp/$PROTOBUF_VER/Makefile",
  }
  ->
  exec {"Build Protobuf":
    cwd => "/tmp/$PROTOBUF_VER",
    path => $path,
    command => "make",
    creates => "/tmp/$PROTOBUF_VER/src/protoc",
  }
  ->
  exec {"Install Protobuf":
    cwd => "/tmp/$PROTOBUF_VER",
    path => $path,
    command => "make install -k",
    creates => "$INSTALL_ROOT/protoc",
  }

  # Build Tez.
  exec {"git clone --branch $TEZ_BRANCH https://github.com/apache/tez tezsrc":
    cwd => "/tmp",
    path => $path,
    require => Exec["Install Protobuf"],
    creates => "/tmp/tezsrc",
    user => "vagrant",
  }
  ->
  exec {"Update Tez":
    command => "git pull",
    cwd => "/tmp/tezsrc",
    path => $path,
    user => "vagrant",
  }
  ->
  file {"Bower is stupid":
    path => '/home/root',
    ensure => directory,
    owner => 'vagrant',
    group => 'vagrant',
    mode => '755',
  }
  ->
  exec {'Build Tez':
    command => 'mvn clean package install -DskipTests -Dhadoop.version=$(hadoop version | head -1 | cut -d" " -f2) -Paws -Phadoop24 -P\\!hadoop26',
    cwd => "/tmp/tezsrc",
    path => $path,
    creates => $target_tez,
    user => "vagrant",
    require => Exec['Add Vendor Repos'],
  }
  ->
  file { "$INSTALL_ROOT/tez":
    ensure => directory,
    owner => root,
    group => root,
    mode => '755',
  }
  ->
  exec {"Deploy Tez Locally":
    cwd => "/tmp/tezsrc/tez-dist/target",
    path => $path,
    command => "tar -C $INSTALL_ROOT/tez -xzvf $target_tez",
  }
  ->
  exec {"Deploy Tez to HDFS":
    cwd => "/tmp/tezsrc",
    path => $path,
    command => "hdfs dfs -copyFromLocal -f $target_tez /hdp/apps/${hdp_version}/tez/tez.tar.gz",
    user => "hdfs",
  }
  ->
  file {"/usr/hdp/current/tez-client":
    ensure => link,
    target => "/usr/hdp/autobuild/tez",
    before => Service['hive-llap'],
  }

  # Build Hive / LLAP.
  exec {"git clone --branch $LLAP_BRANCH https://github.com/apache/hive hivesrc":
    cwd => "/tmp",
    path => $path,
    require => Exec["Install Protobuf"],
    creates => "/tmp/hivesrc",
    user => "vagrant",
  }
  ->
  exec {"Update Hive":
    command => "git pull",
    cwd => "/tmp/hivesrc",
    path => $path,
    user => "vagrant",
  }
  ->
  exec { "Build Hive":
    cwd => "/tmp/hivesrc",
    path => $path,
    command => 'mvn clean package -Denforcer.skip=true -DskipTests=true -Pdir -Pdist -Phadoop-2 -Dhadoop-0.23.version=$(hadoop version | head -1 | cut -d" " -f2) -Dbuild.profile=nohcat',
    creates => $target_hive,
    user => "vagrant",
    require => Exec['Add Vendor Repos'],
  }
  ->
  exec {"Deploy Hive":
    cwd => "/tmp/hivesrc",
    path => $path,
    command => "tar -C $INSTALL_ROOT -xzvf $target_hive",
  }
  ->
  file {"$INSTALL_ROOT/hive":
    ensure => link,
    target => "$INSTALL_ROOT/$hive_package",
  }
  ->
  exec {"hdp-select set hive-server2 autobuild":
    cwd => "/",
    path => $path,
  }
  ->
  exec {"hdp-select set hive-metastore autobuild":
    cwd => "/",
    path => $path,
  }
  ->
  file {"/usr/hdp/current/hive-client":
    ensure => link,
    target => "/usr/hdp/autobuild/hive",
  }
  ->
  file {"/usr/hdp/current/hive-llap":
    ensure => link,
    target => "/usr/hdp/autobuild/hive",
    before => Service['hive-llap'],
  }

  # Configuration files.
  file { "/etc/hive/conf/llap-daemon-site.xml":
    ensure => file,
    content => template('hive_llap/llap-daemon-site.erb'),
  }
  ->
  file { "/etc/hive/conf/llap-daemon-log4j.properties":
    ensure => file,
    source => 'puppet:///modules/hive_llap/llap-daemon-log4j.properties',
    before => Service['hive-llap'],
  }

  # Startup script.
  file { [ '/usr/hdp/autobuild/etc', '/usr/hdp/autobuild/etc/rc.d', '/usr/hdp/autobuild/etc/rc.d/init.d' ]:
    ensure => directory,
    owner => root,
    group => root,
    mode => '755',
  }
  ->
  file { "$start_script":
    ensure => file,
    source => 'puppet:///modules/hive_llap/hive-llap',
    mode => '755',
    replace => true,
  }
  ->
  file { '/etc/init.d/hive-llap':
    ensure => link,
    target => $start_script,
    before => Service['hive-llap'],
  }

  # Start the service.
  service { 'hive-llap':
    ensure => running,
    enable => true,
  }
}