apiVersion: batch/v1
kind: Job
metadata:
  name: __JOB_NAME__
  namespace: __NAMESPACE__
  labels:
    abcvm.io/component: pod-job-dest
    abcvm.io/job: __JOB_NAME__
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels:
        abcvm.io/component: pod-job-dest
        abcvm.io/job: __JOB_NAME__
    spec:
      restartPolicy: Never
      serviceAccountName: __SA_NAME__
      securityContext:
        runAsNonRoot: true
        runAsUser: 1001
        fsGroup: 1001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: seed-deploy
          image: __JOB_IMAGE__
          imagePullPolicy: IfNotPresent
          command: ["/bin/bash", "/scripts/job-seed-deploy.sh"]
          securityContext:
            allowPrivilegeEscalation: false
            runAsNonRoot: true
            runAsUser: 1001
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
          env:
            - name: TARGET_NAMESPACE
              value: "__TARGET_NS__"
            - name: VM_NAME
              value: "__VM_NAME__"
            - name: STORAGE_CLASS
              value: "__STORAGE_CLASS__"
            - name: CATALOG_NAMESPACE
              value: "__CATALOG_NAMESPACE__"
            - name: START_VM
              value: "__START_VM__"
            - name: WORK_DIR
              value: "/work"
          volumeMounts:
            - name: work
              mountPath: /work
            - name: scripts
              mountPath: /scripts
              readOnly: true
      volumes:
        - name: work
          persistentVolumeClaim:
            claimName: __PVC_NAME__
        - name: scripts
          configMap:
            name: __CM_NAME__
            defaultMode: 0750
