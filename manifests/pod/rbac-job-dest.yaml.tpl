apiVersion: v1
kind: ServiceAccount
metadata:
  name: __SA_NAME__
  namespace: __NAMESPACE__
  labels:
    abcvm.io/component: pod-job-dest
    abcvm.io/job: __JOB_NAME__
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: __SA_NAME__
  namespace: __NAMESPACE__
  labels:
    abcvm.io/component: pod-job-dest
    abcvm.io/job: __JOB_NAME__
rules:
  - apiGroups: ["kubevirt.io"]
    resources: ["virtualmachines"]
    verbs: ["create", "get", "list", "watch", "patch"]
  - apiGroups: ["cdi.kubevirt.io"]
    resources: ["datavolumes", "datasources"]
    verbs: ["create", "get", "list", "watch", "delete", "patch", "update"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims", "pods", "pods/log"]
    verbs: ["create", "get", "list", "watch", "delete", "patch", "update"]
  - apiGroups: ["upload.cdi.kubevirt.io"]
    resources: ["uploadtokenrequests"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: __SA_NAME__
  namespace: __NAMESPACE__
  labels:
    abcvm.io/component: pod-job-dest
    abcvm.io/job: __JOB_NAME__
subjects:
  - kind: ServiceAccount
    name: __SA_NAME__
    namespace: __NAMESPACE__
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: __SA_NAME__
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: __SA_NAME__-catalog
  namespace: __CATALOG_NAMESPACE__
  labels:
    abcvm.io/component: pod-job-dest
    abcvm.io/job: __JOB_NAME__
rules:
  - apiGroups: ["cdi.kubevirt.io"]
    resources: ["datavolumes", "datasources"]
    verbs: ["create", "get", "list", "watch", "delete", "patch", "update"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["create", "get", "list", "watch", "delete", "patch", "update"]
  - apiGroups: ["upload.cdi.kubevirt.io"]
    resources: ["uploadtokenrequests"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["namespaces"]
    verbs: ["get"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: __SA_NAME__-catalog
  namespace: __CATALOG_NAMESPACE__
  labels:
    abcvm.io/component: pod-job-dest
    abcvm.io/job: __JOB_NAME__
subjects:
  - kind: ServiceAccount
    name: __SA_NAME__
    namespace: __NAMESPACE__
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: __SA_NAME__-catalog
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: __SA_NAME__-catalog-cloner
  labels:
    abcvm.io/component: pod-job-dest
    abcvm.io/job: __JOB_NAME__
subjects:
  - kind: ServiceAccount
    name: __SA_NAME__
    namespace: __NAMESPACE__
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: abc-vm-catalog-cloner
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: abc-vm-catalog-cloner
  labels:
    abcvm.io/component: pod-job-dest
rules:
  - apiGroups: ["cdi.kubevirt.io"]
    resources: ["datavolumes/source"]
    verbs: ["*"]
