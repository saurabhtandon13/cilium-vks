#!/bin/bash

export version01=v1.19.1
export version02=1.19.1
export registry="registry.vkslab.internal"
export cert="/etc/docker/certs.d/registry.vkslab.internal/ca.crt"

#helm repo add cilium https://helm.cilium.io/

#helm repo update

#helm pull cilium/cilium --version 1.19.0 --untar

find cilium -type f -exec sed -i 's/registry-1.docker.io/$registry/g' {} \;

mkdir -p bundle/ bundle/chart bundle/.imgpkg

helm template --values cilium/values.yaml --set metrics.enabled=true --set cloneStaticSiteFromGit.enabled=true --set cloneStaticSiteFromGit.repository=test --set cloneStaticSiteFromGit.branch=test test ./cilium | kbld -f - --imgpkg-lock-output bundle/.imgpkg/images.yml

cp -r cilium/* bundle/chart/

tree -a bundle/

imgpkg push --bundle  $registry/byo-addons/cni/isovalent/cilium:$version01 --file bundle --registry-ca-cert-path=$cert

imgpkg copy --bundle $registry/byo-addons/cni/isovalent/cilium:$version01 --to-tar bundle.tar --registry-ca-cert-path=$cert

imgpkg copy --tar bundle.tar --to-repo  $registry/byo-addons/cni/isovalent/cilium --registry-ca-cert-path=$cert

imgpkg describe --bundle $registry/byo-addons/cni/isovalent/cilium:$version01 --registry-ca-cert-path=$cert

# create metadata.yaml
cat <<EOF > metadata.yaml
apiVersion: data.packaging.carvel.dev/v1alpha1
kind: PackageMetadata
metadata:
  # This will be the name of our package metadata
  name: cilium.isovalent.com
  namespace: vmware-system-vks-public
spec:
  displayName: "Cilium Carvel Package"
  longDescription: "eBPF-based Networking, Security, and Observability"
  shortDescription: "eBPF-based Networking, Security, and Observability"
  categories:
  - proxy-server
  providerName: VMWare
  maintainers:
  - name: "Cilium"
EOF


# create package_temp.yaml
cat <<EOF > package_temp.yaml
apiVersion: data.packaging.carvel.dev/v1alpha1
kind: Package
metadata:
  name: cilium.isovalent.com.$version02
  namespace: vmware-system-vks-public
spec:
  refName: cilium.isovalent.com
  version: $version02
  releaseNotes:
    The initial release of the Cilium package by wrapping Helm Chart. Cilium Helm chart version is $version02, Cilium version is $version02.
  valuesSchema:
    openAPIv3:
      title: cilium.isovalent.com
      properties:
  template:
    spec:
      fetch:
      - imgpkgBundle:
          image: $registry/byo-addons/cni/isovalent/cilium:$version01
      template:
      - helmTemplate:
          path: chart
          namespace: kube-system
      - kbld:
          paths:
          - '-'
          - .imgpkg/images.yml
      deploy:
      - kapp: {}
EOF

yq -o=yaml '.' bundle/chart/values.schema.json > temp_properties.yaml

yq eval-all 'select(fileIndex==0 and .kind == "Package").spec.valuesSchema.openAPIv3.properties = select(fileIndex==1)' package_temp.yaml temp_properties.yaml -i

sed '/^---/Q' package_temp.yaml > package.yaml


# create acd.yaml
cat <<EOF > acd.yaml
apiVersion: addons.kubernetes.vmware.com/v1alpha1
kind: AddonConfigDefinition
metadata:
  name: cilium.isovalent.com.$version02
  namespace: vmware-system-vks-public
spec:
  templateOutputResources:
    - targetClusterOutput:
        apiVersion: v1
        kind: Secret
        name: '{{.Cluster.name}}-cilium-values'
        namespace: vmware-system-tkg
      template: |-
        stringData:
          values.yaml: |
        {{ toYaml .Values | indent 4}}
  schema:
    openAPIV3Schema:
      type: object
      properties:
EOF


yq eval-all 'select(fileIndex==0 and .kind == "AddonConfigDefinitionPackage").spec.schema.openAPIV3Schema.properties = select(fileIndex==1)' acd.yaml temp_properties.yaml -i

export ACD=$(gzip -c acd.yaml | base64 -w 0)

yq -i '.metadata.annotations."addons.kubernetes.vmware.com/addon-config-definition"=strenv(ACD)' package.yaml

mkdir -p repository repository/.imgpkg repository/packages/ repository/packages/cilium.isovalent.com

cp package.yaml repository/packages/cilium.isovalent.com/$version02.yaml

cp metadata.yaml repository/packages/metadata.yaml

kbld -f repository/packages --imgpkg-lock-output repository/.imgpkg/images.yml --registry-ca-cert-path=$cert

imgpkg push --bundle $registry/byo-addons/cni/cni-addons:v1.0.0 --file repository --registry-ca-cert-path=$cert

imgpkg copy --bundle $registry/byo-addons/cni/cni-addons:v1.0.0 --to-tar repository.tar --registry-ca-cert-path=$cert

imgpkg copy --tar repository.tar --to-repo $registry/byo-addons/cni/cni-addons --registry-ca-cert-path=$cert

cat <<EOF > repo.yaml
apiVersion: addons.kubernetes.vmware.com/v1alpha1
kind: AddonRepository
metadata:
  annotations:
    addons.kubernetes.vmware.com/package-offerings: |
      {
        "repositoryVersion": "1.0.0",
        "packages": {
          "cilium.isovalent.com": {
            "versions": ["$version02"]
          }
        }
      }
  name: cni-addons-repository
  namespace: vmware-system-vks-public
spec:
  fetch:
    imgpkgBundle:
      imageURL: $registry/byo-addons/cni/cni-addons:v1.0.0
  targetRepositoryName: cni-addons-repository
  version: 1.0.0
EOF

cat <<EOF > repo-install.yaml
apiVersion: addons.kubernetes.vmware.com/v1alpha1
kind: AddonRepositoryInstall
metadata:
  name: cni-addons-repository-install
  namespace: vmware-system-vks-public
  annotations:
    addons.kubernetes.vmware.com/target-repository-name: cni-addons-repository
spec:
  addonRepositoryRef:
    name: cni-addons-repository
    namespace: vmware-system-vks-public
EOF


cat <<EOF > addoninstall.yaml
apiVersion: addons.kubernetes.vmware.com/v1alpha1
kind: AddonInstall
metadata:
  labels:
    addons.kubernetes.vmware.com/internal: "true"
  name: cilium
  namespace: vmware-system-vks-public
spec:
  addonRef:
    name: cilium
    namespace: vmware-system-vks-public
  clusters:
    - constraints:
        expression: "cluster.cniRefName() == 'cilium'"
  crossNamespaceSelection: Allowed
  releaseFilter:
    ref:
      name: cilium.isovalent.com.$version02
      namespace: vmware-system-vks-public
EOF

cat <<EOF >  allow-list-cm.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: addon-repo-allow-list-configmap
  namespace: svc-tkg-domain-c1007
data:
  addon-repo-allow-list: cni-addons-repository
EOF


#kubectl apply -f allow-list-cm.yaml 

#kubectl apply -f repo.yaml

#kubectl apply -f repo-install.yaml 

