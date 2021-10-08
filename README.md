Ansible Operator for SSH management of external systems
=======================================================

This is an example of an Ansible Operator for Kubernetes/OpenShift to manage an external NGINX instance and add
custom routing configs to it. It could be seen as a template for any Ansible Operator that needs to do classic
IT-automation work via SSH.

Quick&Dirty Howto, how to get to the state reflected in this repository:

## Prereqs

- Your own Kubernetes/OpenShift with local CLI tooling (kubectl/oc). We used [CodeReady Containers](https://developers.redhat.com/products/codeready-containers/overview)
- Install [operator-sdk](https://github.com/operator-framework/operator-sdk)
- Install [kustomize](https://kubectl.docs.kubernetes.io/installation/kustomize/binaries/) (Yes there is an integrated versionto kubectl but that one is ancient)
- Install [podman](https://podman.io/) if you also want to build the image locally and push it to your cluster. Docker or other tools of course also work, but instructions here are for podman. 
- All instructions are for Linux and Bash shell. Might also work on other OSes with slight changes, who knows...  

## Generate operator project

You should have the following information about your project to be ready:

- A "domain name", most likely your company name. Will go into the API group of your custom resource. We use "example.com". 
- A "project name". We use "ansible-nginx-operator"
- A "group", most likely something that categorizes what you wanna do. Will go into the API group of your custom resource. We use "nginx".
- A "version", kubernetes resource style, we use "v1alpha1"
- A name for the kind of your custom resource, explicitly identifying your current use case. We use "NginxRoute".

Into an empty directory of your choice generate you operator project, run the following (replacing our infos with your infos):

```
operator-sdk init --domain example.com --plugins ansible --project-name ansible-nginx-operator
operator-sdk create api --group nginx --version v1alpha1 --kind NginxRoute --generate-playbook --generate-role
```

## Add properties to the custom resource definition

This step is actually optional as generally this CRD is configured to accept any values, but I think it is good for
making yourself clear how the custom resource should look like. 

Edit `config/crd/bases/<whateverfileisinhere>.yaml`  and add properties to 
path `spec.versions[name: your-version].schema.openAPIV3Schema.properties.spec`.

- Add sub property "properties"
- Below add your properties that you want added

We added this:

```
properties:
  path:
    type: string
  backend_url:
    type: string
```

## Modify Ansible playbook

- Open playbook under `playbooks/<yourresourcename>.yml`
- On property "hosts" replace "localhost" with "all"
- Add additional Ansible collections that you use to the "collections" property. We added:

```
- nginxinc.nginx_core
```

## Implement Ansible role

- Open task file of the generated role under `roles/<yourresourcename>/tasks/main.yml`
- Implement whatever your Ansible playbook should do with the remote server. We added:

```
- include_role:
    name: nginxinc.nginx_core.nginx_config
  vars:
    nginx_config_http_template_enable: true
    nginx_config_http_template:
      route_config:
        conf_file_name: "{{ ansible_operator_meta.name }}.conf"
        servers:
          server1:
            server_name: nginx-engine
            listen:
              http:
                port: 80
            reverse_proxy:
              locations:
                backend:
                  location: "/{{ path }}"
                  proxy_pass: "{{ backend_url }}"
                  rewrites:
                    - "/{{ path }} / break"
```

## Add Ansible collections to requirements.yaml

If your project uses custom Ansible collections you need to add them to the file `requirements.yml` so that they 
actually are installed into the container image of the operator.

- Under property "collections" add name and version of your collection(s), we added:

```
  - name: nginxinc.nginx_core
    version: "0.3.0"
```

## Adapt Dockerfile

The Dockerfile by which the operator is built is preconfigured in the root dir of your operator project.

The base image of the operator is quite slim (based on Red Hat ubi8) and does not even come with an SSH client. We
can add one by installing the "openssh-clients" package when building our operator image.

To be able to install packages we must switch to "root" for this task, as the image's default user is 1001. We switch
back to 1001 after that.

We added this to the "Dockerfile": 

```
USER root
RUN dnf install -y openssh-clients
USER 1001
```

You can of course install yet other/additional packages.
Be aware that you might add packages that need a full RHEL license to run. 

### Create an inventory file

You need an Ansible inventory file which will let it find the target servers it is to work with. Discussing every
inventory configuration option available to Ansible is wayyy beyond the scope here. There are also numerous plugins
which let you connect Ansible to nearly everything capable of doing workload. Yes, might include toasters.   

We added this, a simple YAML inventory file declaring a single server with a fixed IP and user name, mainly so it works
on my local VM setup (a Vagrant machine where NGINX runs):

```
---
demo:
  hosts:
    nginx-engine:
      ansible_host: 192.168.130.15
  vars:
    ansible_user: vagrant
    ansible_become: true
```

For ease we put it into the "playbooks" directory as that one is already copied completely into the container image
(see Dockerfile).

### Provide private key

If you also plan to let Ansible use SSH for its tasks you can simply give it an SSH private key which will get
used automatically, so you can add the corresponding public key everywhere it should have access.

- Create the definition file of a Kubernetes Secret in folder "config/manager"
  (or somewhere else valid if you know how kustomize works). Ours was called "secret_creds.yaml" but is missing in this
  repository for obvious reasons. Contents should look like this:
 
```
kind: Secret
apiVersion: v1
metadata:
  name: creds
stringData:
  SSH_PRIVATE_KEY: |-
    -----BEGIN RSA PRIVATE KEY-----
   Sensible stuff goes here
    -----END RSA PRIVATE KEY-----
```


- Add this file to the kustomization.yaml present in its folder, property "resources". We ended up with this in
`config/manager/kustomization.yaml`:

```
resources:
- manager.yaml
- secret_creds.yaml
```

If you do not use SSH you will need to remove the "- secret_creds.yaml" line here, otherwise building will fail as
the file is not there.

## Mount private key secret to the operator manager deployment

Here we modify the operator manager deployment, defined in file "config/manager.yaml" to actually receive the private
key so Ansible can use it. This is Kubernetes standard functionality for mounting secrets to filesystems, arguably
rather complicated stuff which we will not describe in detail here.
 
In the end you need to mount the secret key contained in your secret (in our example key "SSH_PRIVATE_KEY")
to file "/opt/ansible/.ssh/id_rsa" inside the "manager" container of the deployment (or rather: its pods). 
"/opt/ansible" is configured to be $HOME for the container user so Ansible will automatically pick that up as default
SSH private key. You should also ensure standard file access rights for private keys (octal 0700) so Ansible is allowed
to use it.

If you know how to do that, just go ahead. We did the following:

- In `config/manager/manager.yaml` locate the resource of "kind: Deployment" and "metadata.name: controller-manager" 
- Under path `spec.template.spec` we added

```
volumes:
- name: ssh-key
  secret:
    secretName: creds
    items:
      - key: SSH_PRIVATE_KEY
        path: id_rsa
        mode: 0o700
```

- This makes the volume available to the pods of this deployment, determines the item contained and its desired file
  name plus access rights. But it does not yet determine any mount location.
- Following we do the actual mount to the "manager" container. Under path `spec.template.spec.container[name='manager']`
  we added:

```
volumeMounts:
- mountPath: /opt/ansible/.ssh
  name: ssh-key
```

## Specify inventory on manager deployment

You need to tell the manager to use the inventory file we provided. We do that via environment var ANSIBLE_INVENTORY
containing its path inside the container.

- On the "Deployment" resource use before we added under path `spec.template.spec.container[name='manager'].env`:
    
```    
- name: ANSIBLE_INVENTORY
  value: "/opt/ansible/playbooks/nginx.inventory.yaml"
```

## Specify image docker ref on manager deployment

You also need to specify the actual image name where the ansible container image will be available to your cluster under
`spec.template.spec.container[name='manager'].image` of the Deployment resource.

Loads of options depending on you using plain Kubernetes or OpenShift or whatnot, and where that image then actually
is located (ImageStream, local registry, docker hub ....). So we cannot help you much here and you might already know
how to make a container image available to your OpenShift/Kubernetes cluster. Once you have your image in a registry
reachable from your cluster you can simply put the respective docker ref string into the `image` property here.

What we did: We will simple push a locally built image to the registry. The docker ref syntax of the OpenShift registry
is `registry-dns/openshift-project/image-name:tag`. On CodeReady Containers and on a project
"ansible-nginx-operator-system" this is what we used:
 
```
image: default-route-openshift-image-registry.apps-crc.testing/ansible-nginx-operator-system/controller:latest
```

NOTE: If you plan to follow the "what we did" instructions don't push your image yet, as the target project 
"ansible-nginx-operator-system" on that docker ref is not yet known to OpenShift.

Deploy operator and push image
==========

Now we need to get everything on the cluster: Kubernetes Resources and Operator image

If you follow the "what we did" path and you also use a local CodeReady Containers installation for your OpenShift: 
There is a shell script "push-everything-to-crc.sh" in this repo. It *should* does everything necessary when your local
oc tool is logged in on your CRC cluster and you have podman+kustomize installed. It will:

- Deploy all Kubernetes resources of the operator (defined in config/default/kustomization.yaml)
- Build the image locally
- Login to CRC OpenShift registry
- Push the image to the registry

Otherwise: We are not covering the part here to get your image to your cluster as there are too many options. 
But you can deploy the kubernetes resources the following:

- Go into folder "config/default"
- Run:

```
kustomize build . | kubectl apply -f -
```

It might take some time for the Operator pod to pick up the now available image. To speed things up, delete the old 
pod which will instantly get replaced.

Finished?!
==========

If everything went well you now have a working Operator deployment deployed to a project/namespace
"<your-project-name>-operator-system". It just has nothing to do yet as there is no custom resource it could use.

Under "config/samples/<group>_<version>_<resourcekind>.yaml" the Operator SDK generated a sample of a resource,
but yet without your added custom properties. If you add these and then apply the resource to Kubernetes via:

```
kubectl apply -f config/samples/<group>_<version>_<resourcekind>.yaml 
```

Then your operator should pick this up within seconds and perform its magic.

Here is our sample:

```
apiVersion: nginx.example.com/v1alpha1
kind: NginxRoute
metadata:
  name: bar-route
spec:
  path: bar
  backend_url: http://python-sample-sample-app.apps-crc.testing
```