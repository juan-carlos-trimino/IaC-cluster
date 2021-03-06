/***
-------------------------------------------------------
A Terraform reusable module for deploying microservices
-------------------------------------------------------
Define input variables to the module.
***/
variable app_name {
  type = string
}
variable namespace {
  type = string
}
variable service_name {
  type = string
}
variable api_auth_token {
  type = string
}
variable chart_name {
  type = string
  description = "Ingress Controller Helm chart name."
  default = "traefik"
}
variable chart_repo {
  type = string
  description = "Using the official Traefik helm chart (Ingress Controller)."
  default = "https://helm.traefik.io/traefik"
}
variable chart_version {
  type = string
  description = "Ingress Controller Helm repository version."
  # To use the latest version, go to https://artifacthub.io/ and type "traefik" on the edit box.
  default = "10.19.4"
}

resource "null_resource" "scc-traefik" {
  triggers = {
    always_run = timestamp()
  }
  #
  provisioner "local-exec" {
    command = "oc apply -f ./utility-files/traefik/mem-traefik-scc.yaml"
  }
  #
  provisioner "local-exec" {
    when = destroy
    command = "oc delete scc mem-traefik-scc"
  }
}

# See 'env:' in ..\..\..\utility-files\traefik\values.yaml.
resource "kubernetes_secret" "secret" {
  metadata {
    name = "${var.service_name}-provider-secret"
    namespace = var.namespace
    labels = {
      app = var.app_name
    }
  }
  # Plain-text data.
  data = {
    api_auth_token = var.api_auth_token
  }
  type = "Opaque"
}

# A ServiceAccount is used by an application running inside a pod to authenticate itself with the
# API server. A default ServiceAccount is automatically created for each namespace; each pod is
# associated with exactly one ServiceAccount, but multiple pods can use the same ServiceAccount. A
# pod can only use a ServiceAccount from the same namespace.
#
# Using the least-privilege approach with the namespace-scoped RoleBindings. In general, this is a
# preferred approach if a cluster's namespaces do not change dynamically and if Traefik is not
# required to watch all cluster namespaces.
resource "kubernetes_service_account" "service_account" {
  metadata {
    name = "${var.service_name}-service-account"
    namespace = var.namespace
    labels = {
      app = var.app_name
    }
  }
}

# Roles define WHAT can be done; role bindings define WHO can do it.
# The distinction between a Role/RoleBinding and a ClusterRole/ClusterRoleBinding is that the Role/
# RoleBinding is a namespaced resource; ClusterRole/ClusterRoleBinding is a cluster-level resource.
# A Role resource defines what actions can be taken on which resources; i.e., which types of HTTP
# requests can be performed on which RESTful resources.
resource "kubernetes_role" "role" {
  metadata {
    name = "${var.service_name}-role"
    namespace = var.namespace
    labels = {
      app = var.app_name
    }
  }
  rule {
    # Resources in the core apiGroup, which has no name - hence the "".
    api_groups = [""]
    verbs = ["get", "watch", "list"]
    # The plural form must be used when specifying resources.
    resources = ["services", "endpoints", "secrets"]
  }
  rule {
    api_groups = ["traefik.containo.us/v1alpha1"]
    verbs = ["get", "watch", "list"]
    resources = [
      "middlewares",
      "ingressroutes",
      "traefikservices",
      "ingressroutetcps",
      "ingressrouteudps",
      "tlsoptions",
      "tlsstores",
      "serverstransports"
    ]
  }
  rule {
    api_groups = ["extensions", "networking.k8s.io"]
    verbs = ["get", "watch", "list"]
    resources = ["ingresses", "ingressclasses"]
  }
  rule {
    api_groups = ["extensions", "networking.k8s.io"]
    verbs = ["update"]
    resources = ["ingresses/status"]
  }
  rule {
    api_groups = ["security.openshift.io"]
    verbs = ["use"]
    resources = ["securitycontextconstraints"]
    resource_names = ["mem-traefik-scc"]
  }
}

# Bind the role to the service account.
resource "kubernetes_role_binding" "role_binding" {
  metadata {
    name = "${var.service_name}-role-binding"
    namespace = var.namespace
    labels = {
      app = var.app_name
    }
  }
  # A RoleBinding always references a single Role, but it can bind the Role to multiple subjects.
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind = "Role"
    # This RoleBinding references the Role specified below...
    name = kubernetes_role.role.metadata[0].name
  }
  # ... and binds it to the specified ServiceAccount in the specified namespace.
  subject {
    # The default permissions for a ServiceAccount don't allow it to list or modify any resources.
    kind = "ServiceAccount"
    name = kubernetes_service_account.service_account.metadata[0].name
    namespace = kubernetes_service_account.service_account.metadata[0].namespace
  }
}

# Traefik is a Cloud Native Edge Router that will work as an ingress controller to a Kubernetes
# cluster. It will be responsible to make sure that when the traffic from a web application hits
# the Kubernetes cluster, it will go to the right Service. Also, it makes it very easy to assign
# an SSL/TLS certificate to the web application.
#
# Notes:
# 1. To watch the traefik's logs:
#    $ kubectl logs -n memories -l app.kubernetes.io/name=traefik -f
# 2. Traefik supports the ACME protocol used by Let's Encrypt.
# 3. By default, the chart will deploy Traefik in LoadBalancer mode.
# 4. EntryPoints are the network entry points into Traefik. They define the port which will receive
#    the packets, and whether to listen for TCP or UDP. The Traefik Helm chart deployment creates
#    the following entrypoints:
#    * web: It is used for all HTTP requests. The Kubernetes LoadBalancer service maps port 80 to
#           the web entrypoint.
#    * websecure: It is used for all HTTPS requests. The Kubernetes LoadBalancer service maps port
#                 443 to the websecure entrypoint.
#    * traefik: Kubernetes uses the Traefik Proxy entrypoint for pod liveliness check. The Traefik
#               dashboard and API are available on the Traefik entrypoint.
#    Applications are configured either on the web or the websecure entrypoints.
#    web - port 8000 (exposed as port 80)
#    websecure - port 8443 (exposed as port 443)
#    traefik - port 9000 (not exposed)
#    metrics - port 9100 (not exposed)
resource "helm_release" "traefik" {
  # depends_on = [
  #   kubernetes_namespace.ns
  # ]
  chart = var.chart_name
  repository = var.chart_repo
  version = var.chart_version
  namespace = var.namespace
  name = var.service_name
  values = [file("./utility-files/traefik/values.yaml")]
  # timeout = 180  # Seconds.
}
