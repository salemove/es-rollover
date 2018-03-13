@Library('cve-monitor') _

def MAIN_BRANCH                    = 'master'
def DOCKER_REPOSITORY_NAME         = 'es-rollover'
def DOCKER_REGISTRY_URL            = 'https://662491802882.dkr.ecr.us-east-1.amazonaws.com'
def DOCKER_REGISTRY_CREDENTIALS_ID = 'ecr:us-east-1:ecr-docker-push'

withResultReporting(slackChannel: '#tm-is') {
  inDockerAgent(containers: [imageScanner.container()]) {
    def image, shortCommit
    stage('Build') {
      checkout(scm)
      shortCommit = sh(returnStdout: true, script: 'git log -n 1 --pretty=format:"%h"').trim()
      ansiColor('xterm') {
        image = docker.build(DOCKER_REPOSITORY_NAME)
      }
    }
    stage('Scan image') {
      imageScanner.scan(image)
    }
    if (BRANCH_NAME == MAIN_BRANCH) {
      stage('Publish docker image') {
        echo("Publishing docker image ${image.imageName()} with tag ${shortCommit}")
        docker.withRegistry(DOCKER_REGISTRY_URL, DOCKER_REGISTRY_CREDENTIALS_ID) {
          image.push(shortCommit)
        }
      }
    } else {
      echo("${BRANCH_NAME} is not the master branch. Not publishing the docker image.")
    }
  }
}
