apiVersion: v1
kind: ServiceAccount
metadata:
  name: __SA_NAME__
  namespace: __NAMESPACE__
  labels:
    abcvm.io/component: pod-job-build
    abcvm.io/job: __JOB_NAME__
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: __SA_NAME__
  namespace: __NAMESPACE__
  labels:
    abcvm.io/component: pod-job-build
    abcvm.io/job: __JOB_NAME__
rules:
  - apiGroups: ["kubevirt.io"]
    resources: ["virtualmachines", "virtualmachineinstances"]
    verbs: ["get", "list", "watch", "patch", "update"]
  - apiGroups: ["kubevirt.io"]
    resources: ["virtualmachines/stop", "virtualmachineinstances/stop"]
    verbs: ["update", "patch"]
  - apiGroups: ["subresources.kubevirt.io"]
    resources: ["virtualmachines/stop", "virtualmachines/start", "virtualmachineinstances/stop"]
    verbs: ["update"]
  - apiGroups: ["export.kubevirt.io"]
    resources: ["virtualmachineexports"]
    verbs: ["create", "get", "list", "watch", "delete"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims", "pods", "pods/log", "secrets", "services"]
    verbs: ["get", "list", "watch", "create", "delete"]
  - apiGroups: [""]
    resources: ["pods/portforward"]
    verbs: ["create"]
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
    abcvm.io/component: pod-job-build
    abcvm.io/job: __JOB_NAME__
subjects:
  - kind: ServiceAccount
    name: __SA_NAME__
    namespace: __NAMESPACE__
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: __SA_NAME__
