apiVersion: batch/v1
kind: Job
metadata:
  name: __JOB_NAME__
  namespace: __NAMESPACE__
  labels:
    abcvm.io/component: pod-job-build
    abcvm.io/job: __JOB_NAME__
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 86400
  template:
    metadata:
      labels:
        abcvm.io/component: pod-job-build
        abcvm.io/job: __JOB_NAME__
    spec:
      restartPolicy: Never
      serviceAccountName: __SA_NAME__
      containers:
        - name: build
          image: __JOB_IMAGE__
          imagePullPolicy: IfNotPresent
          command: ["/bin/bash", "/scripts/job-build.sh"]
          env:
            - name: NS
              value: "__SOURCE_NS__"
            - name: VM
              value: "__SOURCE_VM__"
            - name: VERSION
              value: "__VERSION__"
            - name: KEEP_EXPORT
              value: "__KEEP_EXPORT__"
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
