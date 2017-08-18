provider "aws" {
  region = "${var.aws_region}"
}

resource "aws_security_group" "microservices-demo-staging-k8s" {
  name        = "microservices-demo-staging-k8s"
  description = "allow all internal traffic, all traffic from bastion and http from anywhere"
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = "true"
  }
  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = ["${var.bastion_security_group}"]
  }
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "k8s-node" {
  depends_on      = [ "aws_instance.k8s-master" ] 
  count           = "${var.nodecount}"
  instance_type   = "${var.node_instance_type}"
  ami             = "${lookup(var.aws_amis, var.aws_region)}"
  key_name        = "${var.key_name}"
  security_groups = ["${aws_security_group.microservices-demo-staging-k8s.name}"]
  tags {
    Name = "microservices-demo-staging-node"
  }

  root_block_device {
    volume_type = "gp2"
    volume_size = "50"
  }

  connection {
    user        = "${var.instance_user}"
    private_key = "${file("${var.private_key_file}")}"
    host        = "${self.private_ip}"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo sh -c 'curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -'",
      "sudo sh -c 'echo deb http://apt.kubernetes.io/ kubernetes-xenial main > /etc/apt/sources.list.d/kubernetes.list'",
      "sudo apt-get update",
      "sudo apt-get install -y docker.io kubelet kubeadm kubectl kubernetes-cni"
    ]
  }

  provisioner "local-exec" {
    command = "ssh -i ${var.private_key_file} -o StrictHostKeyChecking=no ubuntu@${self.private_ip} sudo `cat join.cmd`"
  }
}

resource "aws_instance" "k8s-master" {
  instance_type   = "${var.master_instance_type}"
  ami             = "${lookup(var.aws_amis, var.aws_region)}"
  key_name        = "${var.key_name}"
  security_groups = ["${aws_security_group.microservices-demo-staging-k8s.name}"]
  tags {
    Name = "microservices-demo-staging-master"
  }

  root_block_device {
    volume_type = "gp2"
    volume_size = "50"
  }

  connection {
    user        = "${var.instance_user}"
    private_key = "${file("${var.private_key_file}")}"
    host        = "${self.private_ip}"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo sh -c 'curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -'",
      "sudo sh -c 'echo deb http://apt.kubernetes.io/ kubernetes-xenial main > /etc/apt/sources.list.d/kubernetes.list'",
      "sudo apt-get update",
      "sudo apt-get install -y docker.io kubelet kubeadm kubectl kubernetes-cni",
      "mkdir -p /home/ubuntu/microservices-demo/deploy/kubernetes/manifests"
    ]
  }

  provisioner "file" {
    source = "~/microservices-demo/deploy/kubernetes/manifests/"
    destination = "/home/ubuntu/microservices-demo/deploy/kubernetes"
  }

  provisioner "local-exec" {
    command = "ssh -i ${var.private_key_file} -o StrictHostKeyChecking=no ubuntu@${self.private_ip} sudo kubeadm init | grep -e --token > join.cmd"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo cp /etc/kubernetes/admin.conf ~/config",
      "sudo chown ubuntu: ~/config"
    ]
  }

  provisioner "local-exec" {
    command = "scp -i ${var.private_key_file} -o StrictHostKeyChecking=no ubuntu@${self.private_ip}:~/config ~/.kube/"
  }
}

resource "null_resource" "weave" {
  depends_on = [ "aws_instance.k8s-node" ]

  connection {
    host        = "${aws_instance.k8s-master.private_ip}"
    user        = "${var.instance_user}"
    private_key = "${file("${var.private_key_file}")}"
  }

  provisioner "remote-exec" {
    inline = [
      "kubectl apply -f https://git.io/weave-kube-1.6",
      "kubectl apply -f 'https://cloud.weave.works/k8s/scope.yaml?t=${var.weave_cloud_token}'",
      "kubectl apply -f 'https://cloud.weave.works/k8s/flux.yaml?t=${var.weave_cloud_token}'",
      "kubectl apply -f 'https://cloud.weave.works/k8s/cortex.yaml?t=${var.weave_cloud_token}'"
    ]
  }
}

resource "null_resource" "sock-shop" {
  depends_on = [ "null_resource.weave" ]

  connection {
    host        = "${aws_instance.k8s-master.private_ip}"
    user        = "${var.instance_user}"
    private_key = "${file("${var.private_key_file}")}"
  }

  provisioner "remote-exec" {
    inline = [
      "kubectl apply -f ~/microservices-demo/deploy/kubernetes/manifests/sock-shop-ns.yaml -f ~/microservices-demo/deploy/kubernetes/manifests/zipkin-ns.yaml -f ~/microservices-demo/deploy/kubernetes/manifests"
    ]
  }
}

resource "null_resource" "cleanup" {
  depends_on = [ "aws_instance.k8s-node" ]
  provisioner "local-exec" {
    command = "rm join.cmd"
  }
}

resource "aws_elb" "microservices-demo-staging-k8s" {
  depends_on = [ "aws_instance.k8s-node" ]
  name = "microservices-demo-staging-k8s"
  instances = ["${aws_instance.k8s-node.*.id}"]
  availability_zones = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
  security_groups = ["${aws_security_group.microservices-demo-staging-k8s.id}"]

  listener {
    lb_port = 80
    instance_port = 30001
    lb_protocol = "http"
    instance_protocol = "http"
  }
}
