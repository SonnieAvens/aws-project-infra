############################
# Latest Amazon Linux 2023 AMI
############################
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

############################
# Security Group
############################
resource "aws_security_group" "pg_cluster" {
  name        = "${var.project_name}-sg"
  description = "PostgreSQL cluster security group"
  vpc_id      = aws_vpc.main.id

  # SSH + EC2 Instance Connect (us-east-1 range: 18.206.107.24/29)
  ingress {
    description = "SSH and EC2 Instance Connect"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0", "18.206.107.24/29"]
  }

  # PostgreSQL between cluster nodes and external clients
  ingress {
    description = "PostgreSQL"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Patroni REST API between cluster nodes
  ingress {
    description = "Patroni REST API (inter-node)"
    from_port   = 8008
    to_port     = 8008
    protocol    = "tcp"
    self        = true
  }

  # etcd between cluster nodes
  ingress {
    description = "etcd client (inter-node)"
    from_port   = 2379
    to_port     = 2380
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-sg" }
}

############################
# IAM Role — SSM + Secrets Manager access
############################
resource "aws_iam_role" "pg_cluster" {
  name = "${var.project_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.pg_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Allow EC2 nodes to discover cluster peers by tag
resource "aws_iam_role_policy" "ec2_describe" {
  name = "${var.project_name}-ec2-describe"
  role = aws_iam_role.pg_cluster.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:DescribeInstances"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "pg_cluster" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.pg_cluster.name
}

############################
# 3 EC2 Instances — PostgreSQL Cluster
# Node 0 = Primary | Nodes 1 & 2 = Replicas
# Distributed across 2 public subnets
############################
resource "aws_instance" "pg_cluster" {
  count                       = 3
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.pg_cluster_instance_type
  subnet_id                   = aws_subnet.public[count.index % 2].id
  vpc_security_group_ids      = [aws_security_group.pg_cluster.id]
  iam_instance_profile        = aws_iam_instance_profile.pg_cluster.name
  associate_public_ip_address = true
  key_name                    = var.ec2_key_name != "" ? var.ec2_key_name : null

  user_data = <<-EOF
    #!/bin/bash
    set -e
    exec > /var/log/pg-cluster-bootstrap.log 2>&1

    NODE_INDEX=${count.index}
    NODE_NAME="pg-node-${count.index}"
    CLUSTER_NAME="${var.project_name}"
    REGION="${var.aws_region}"
    PGDATA="/var/lib/pgsql/17/data"
    PG_PORT=5432
    PATRONI_PORT=8008
    ETCD_CLIENT_PORT=2379
    ETCD_PEER_PORT=2380
    REPLICATION_USER="replicator"
    REPLICATION_PASS="Repl1c@t0r$(openssl rand -hex 8)"
    POSTGRES_PASS="P@ssw0rd$(openssl rand -hex 8)"

    echo "=== Installing packages ==="
    dnf update -y
    dnf install -y postgresql17-server postgresql17 python3 python3-pip gcc python3-devel etcd awscli

    pip3 install patroni[etcd] psycopg2-binary

    echo "=== Waiting for all 3 cluster nodes to be running ==="
    MY_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

    for i in $(seq 1 30); do
      PEER_IPS=$(aws ec2 describe-instances \
        --region "$REGION" \
        --filters "Name=tag:Project,Values=$CLUSTER_NAME" \
                  "Name=instance-state-name,Values=running" \
        --query "Reservations[].Instances[].PrivateIpAddress" \
        --output text | tr '\t' '\n' | sort)
      NODE_COUNT=$(echo "$PEER_IPS" | grep -c '\.' || true)
      if [ "$NODE_COUNT" -ge 3 ]; then
        break
      fi
      echo "Waiting for peers... ($NODE_COUNT/3 running)"
      sleep 10
    done

    echo "Discovered peers: $PEER_IPS"
    ETCD_INITIAL_CLUSTER=""
    IDX=0
    for IP in $PEER_IPS; do
      ETCD_INITIAL_CLUSTER="$${ETCD_INITIAL_CLUSTER}pg-node-$IDX=http://$IP:$ETCD_PEER_PORT,"
      IDX=$((IDX+1))
    done
    ETCD_INITIAL_CLUSTER="$${ETCD_INITIAL_CLUSTER%,}"

    MY_ETCD_NAME=$(aws ec2 describe-instances \
      --region "$REGION" \
      --filters "Name=private-ip-address,Values=$MY_IP" \
      --query "Reservations[0].Instances[0].Tags[?Key=='Name'].Value" \
      --output text | sed 's/${var.project_name}-node-/pg-node-/' | sed 's/primary/0/' | sed 's/replica-//')
    [ -z "$MY_ETCD_NAME" ] && MY_ETCD_NAME="$NODE_NAME"

    echo "=== Configuring etcd ==="
    cat > /etc/etcd/etcd.conf <<ETCDCONF
    ETCD_NAME="$NODE_NAME"
    ETCD_DATA_DIR="/var/lib/etcd/default.etcd"
    ETCD_LISTEN_CLIENT_URLS="http://0.0.0.0:$ETCD_CLIENT_PORT"
    ETCD_ADVERTISE_CLIENT_URLS="http://$MY_IP:$ETCD_CLIENT_PORT"
    ETCD_LISTEN_PEER_URLS="http://0.0.0.0:$ETCD_PEER_PORT"
    ETCD_INITIAL_ADVERTISE_PEER_URLS="http://$MY_IP:$ETCD_PEER_PORT"
    ETCD_INITIAL_CLUSTER="$ETCD_INITIAL_CLUSTER"
    ETCD_INITIAL_CLUSTER_STATE="new"
    ETCD_INITIAL_CLUSTER_TOKEN="$CLUSTER_NAME-etcd"
    ETCDCONF

    systemctl enable etcd
    systemctl start etcd

    echo "=== Configuring Patroni ==="
    ETCD_HOSTS=$(echo "$PEER_IPS" | awk '{printf "%s:2379,", $1}' | sed 's/,$//')

    mkdir -p /etc/patroni
    cat > /etc/patroni/config.yml <<PATRONICONF
    scope: $CLUSTER_NAME
    namespace: /db/
    name: $NODE_NAME

    restapi:
      listen: 0.0.0.0:$PATRONI_PORT
      connect_address: $MY_IP:$PATRONI_PORT

    etcd3:
      hosts: $ETCD_HOSTS

    bootstrap:
      dcs:
        ttl: 30
        loop_wait: 10
        retry_timeout: 10
        maximum_lag_on_failover: 1048576
        postgresql:
          use_pg_rewind: true
          use_slots: true
          parameters:
            wal_level: replica
            hot_standby: "on"
            max_wal_senders: 5
            max_replication_slots: 5

      initdb:
        - encoding: UTF8
        - data-checksums

      pg_hba:
        - host replication $REPLICATION_USER 0.0.0.0/0 md5
        - host all all 0.0.0.0/0 md5

      users:
        admin:
          password: $POSTGRES_PASS
          options:
            - createrole
            - createdb

    postgresql:
      listen: 0.0.0.0:$PG_PORT
      connect_address: $MY_IP:$PG_PORT
      data_dir: $PGDATA
      bin_dir: /usr/bin
      authentication:
        replication:
          username: $REPLICATION_USER
          password: $REPLICATION_PASS
        superuser:
          username: postgres
          password: $POSTGRES_PASS

    tags:
      nofailover: false
      noloadbalance: false
      clonefrom: false
      nosync: false
    PATRONICONF

    echo "=== Creating Patroni systemd service ==="
    cat > /etc/systemd/system/patroni.service <<SERVICE
    [Unit]
    Description=Patroni PostgreSQL HA
    After=syslog.target network.target etcd.service

    [Service]
    Type=simple
    User=postgres
    Group=postgres
    ExecStart=/usr/local/bin/patroni /etc/patroni/config.yml
    KillMode=process
    TimeoutSec=30
    Restart=on-failure

    [Install]
    WantedBy=multi-user.target
    SERVICE

    chown -R postgres:postgres /etc/patroni
    mkdir -p $PGDATA
    chown -R postgres:postgres $(dirname $PGDATA)

    systemctl daemon-reload
    systemctl enable patroni
    systemctl start patroni

    echo "=== Bootstrap complete. Patroni started on $NODE_NAME ($MY_IP) ==="
  EOF

  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # Force recreation when user_data changes so bootstrap script reruns
  user_data_replace_on_change = true

  tags = {
    Name = "${var.project_name}-node-${count.index == 0 ? "primary" : "replica-${count.index}"}"
    Role = count.index == 0 ? "primary" : "replica"
  }
}
