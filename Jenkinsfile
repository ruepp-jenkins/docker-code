properties(
    [
        githubProjectProperty(
            displayName: 'docker-code',
            projectUrlStr: 'https://github.com/ruepp-jenkins/docker-code'
        ),
        // Every agent's tags derive from the same datestamp. Concurrent builds of the same branch
        // would write the same intermediate tags, and a manifest could pick up half of one build and
        // half of another.
        disableConcurrentBuilds(abortPrevious: true)
    ]
)

// `checkout scm` rather than a `git` step with a URL and a credentials id spelled out here.
//
// Two reasons. The job already knows both — it found this file by cloning the repository — so
// repeating them is a second copy that can disagree with the first, and it disagreed: an SSH remote
// and an ssh credentials id, on a job whose branch indexing authenticates as a GitHub App over
// HTTPS. And `scm` carries the exact revision that produced this Jenkinsfile, so every agent checks
// out the same commit even if the branch moves mid-build.
//
// Note also that there are no `def` constants at the top of this file. In a Declarative pipeline a
// top-level `def` is a local of the script's own run method, invisible to the methods below — the
// reference simply fails at runtime with MissingPropertyException. tests/pipeline.bats asserts that
// none come back.
def checkoutRepo() {
    checkout scm
    sh 'chmod +x scripts/*.sh'
}

// One image, one architecture. Identical for the base and for every agent, so it lives in one place;
// the post blocks below cannot move here — junit and cleanWs are stage directives, not steps.
//
// The caller checks the repository out, not this function: a stage that builds every image does it
// once rather than once per agent into the same workspace.
def buildImage(String agentId, String arch, String platform) {
    withEnv(["AGENT_ID=${agentId}", "EXPECTED_PLATFORM=${platform}", "TEST_REPORT_SUFFIX=${arch}"]) {
        sh './scripts/start.sh'

        // The image was pushed without a tag, so its digest is the only handle on it — and it is on
        // the wrong machine. stash is the one channel declarative pipelines offer between agents. It
        // has to happen here in steps: the post block below wipes the workspace.
        stash name: "digest-${agentId}-${arch}", includes: "digest-${agentId}-${arch}.txt"
    }
}

def publishManifest(String agentId) {
    withEnv(["AGENT_ID=${agentId}"]) {
        unstash "digest-${agentId}-amd64"
        unstash "digest-${agentId}-arm64"
        sh './scripts/docker_manifest.sh'
    }
}

pipeline {
    // No global agent: the whole point of this pipeline is that the architecture builds run on
    // different machines, so every stage names its own.
    agent none

    environment {
        // The stem; scripts/docker_tags.sh appends -base or -<agent>, so every tool lives in its own
        // repository rather than in one tag list nobody can read.
        IMAGE_FULLNAME = 'ruepp/docker-code'
        DOCKER_API_PASSWORD = credentials('DOCKER_API_PASSWORD')

        // Every agent builds its own architecture and nothing else. 'host' is what tells
        // scripts/docker_platforms.sh to skip the QEMU registration: with a machine per platform
        // there is nothing left to emulate, and the --privileged binfmt container is no longer
        // needed on either agent.
        DOCKER_PLATFORMS = 'host'

        // The architectures scripts/docker_manifest.sh joins into one manifest list. Adding a
        // platform is a parallel branch below plus an entry here — the two have to stay in step.
        MANIFEST_ARCHS = 'amd64 arm64'
    }

    triggers {
        // Reasons to rebuild without a commit: one of the tools released a new version, or the
        // base image did. Both matter because the image is the update path for its users — every
        // tool is installed system-wide with its auto-updater off, and the base image carries the OS
        // security updates. Neither touches the persistent home directories, so an update costs
        // users nothing: no new login, no lost sessions.
        //
        // Not watched, deliberately: the Docker CE, NodeSource and GitHub CLI apt repositories. They
        // publish far more often than they matter here, and a base image refresh already rebuilds
        // the layer that installs them. Cursor CLI is not watched either — its installer is a shell
        // script with no version endpoint to poll.
        URLTrigger(
            cronTabSpec: 'H/30 * * * *',
            labelRestriction: 'urltrigger',
            entries: [
                // One entry per tool, each the version the package registry serves — which changes
                // exactly once per release. tests/pipeline.bats checks that every agent installing
                // from npm has an entry here, so a tool added without one fails the suite.
                URLTriggerEntry(
                    url: 'https://registry.npmjs.org/@anthropic-ai/claude-code/latest',
                    contentTypes: [JsonContent([JsonContentEntry(jsonPath: '$.version')])]
                ),
                URLTriggerEntry(
                    url: 'https://registry.npmjs.org/@openai/codex/latest',
                    contentTypes: [JsonContent([JsonContentEntry(jsonPath: '$.version')])]
                ),
                URLTriggerEntry(
                    url: 'https://registry.npmjs.org/@google/gemini-cli/latest',
                    contentTypes: [JsonContent([JsonContentEntry(jsonPath: '$.version')])]
                ),
                URLTriggerEntry(
                    url: 'https://registry.npmjs.org/@qwen-code/qwen-code/latest',
                    contentTypes: [JsonContent([JsonContentEntry(jsonPath: '$.version')])]
                ),
                URLTriggerEntry(
                    url: 'https://registry.npmjs.org/opencode-ai/latest',
                    contentTypes: [JsonContent([JsonContentEntry(jsonPath: '$.version')])]
                ),
                URLTriggerEntry(
                    url: 'https://registry.npmjs.org/@github/copilot/latest',
                    contentTypes: [JsonContent([JsonContentEntry(jsonPath: '$.version')])]
                ),
                // Mistral Vibe is the one agent that comes from PyPI rather than npm, so its
                // trigger reads a different URL shape — the version sits under .info.version.
                URLTriggerEntry(
                    url: 'https://pypi.org/pypi/mistral-vibe/json',
                    contentTypes: [JsonContent([JsonContentEntry(jsonPath: '$.info.version')])]
                ),
                // Kiro CLI comes from AWS's own download channel rather than a package registry.
                // The channel manifest is what agents/kiro/Dockerfile installs from and verifies
                // against, so watching it tracks exactly what a rebuild would pick up.
                URLTriggerEntry(
                    url: 'https://prod.download.cli.kiro.dev/stable/latest/manifest.json',
                    contentTypes: [JsonContent([JsonContentEntry(jsonPath: '$.version')])]
                ),
                // The only image the build pulls: `ubuntu:24.04` backs both the runtime stage and
                // the test stage. The tag has to track base/Dockerfile's UBUNTU_TAG. The digest is
                // the manifest list's, so it moves whenever any published architecture is rebuilt —
                // which is exactly when a rebuild picks up new OS patches.
                //
                // hub.docker.com rather than registry-1.docker.io: the registry API answers 401
                // without a bearer token, which URLTrigger cannot obtain.
                URLTriggerEntry(
                    url: 'https://hub.docker.com/v2/repositories/library/ubuntu/tags/24.04',
                    contentTypes: [JsonContent([JsonContentEntry(jsonPath: '$.digest')])]
                )
            ]
        )
    }

    stages {
        stage('Prepare') {
            // The datestamp goes into every tag, including the ones other agents push and the ones
            // the manifest steps look up. Computed once here rather than by each agent: two machines
            // running `date` disagree across midnight and across time zones, and a manifest would
            // then reference a tag that was never written.
            //
            // The agent list is read here too, from the directories themselves. That is what keeps
            // "add a folder under agents/" true all the way through CI — no list in this file to
            // forget to update.
            agent { label 'docker' }
            steps {
                checkoutRepo()
                script {
                    env.DATESTAMP = sh(script: 'date +%Y%m%d', returnStdout: true).trim()
                    env.AGENT_IDS = sh(
                        script: 'ls -1 agents | while read -r d; do [ -f "agents/$d/agent.env" ] && echo "$d"; done | sort | tr "\\n" " "',
                        returnStdout: true
                    ).trim()
                }
                echo "Tag base for this build: ${env.DATESTAMP}"
                echo "Agents in this build:    ${env.AGENT_IDS}"
            }
            post {
                always {
                    cleanWs()
                }
            }
        }

        stage('Base') {
            // The shared layer, and the only place the test suite runs. Its `verified` stage refuses
            // to produce an image when a test failed, and every agent image copies the resulting
            // stamp — so one red test blocks every agent rather than only the one that was touched.
            parallel {
                stage('base amd64') {
                    agent { label 'docker' }
                    steps {
                        checkoutRepo()
                        buildImage('base', 'amd64', 'linux/amd64')
                    }
                    post {
                        always {
                            // 'always', so the report is published even when the build fails — which
                            // is precisely when knowing which test broke is worth something.
                            // allowEmptyResults stays false on purpose: a missing report means the
                            // tests did not run, and that should fail loudly rather than pass
                            // quietly.
                            junit testResults: 'test-results/*.junit.xml',
                                  allowEmptyResults: false,
                                  keepProperties: true
                            sh './scripts/docker_cleanup.sh'
                            cleanWs()
                        }
                    }
                }
                stage('base arm64') {
                    agent { label 'oracle_docker' }
                    steps {
                        checkoutRepo()
                        buildImage('base', 'arm64', 'linux/arm64')
                    }
                    post {
                        always {
                            junit testResults: 'test-results/*.junit.xml',
                                  allowEmptyResults: false,
                                  keepProperties: true
                            sh './scripts/docker_cleanup.sh'
                            cleanWs()
                        }
                    }
                }
            }
        }

        stage('Base manifest') {
            // Has to finish before any agent builds: the agent Dockerfiles resolve the base by tag,
            // and this step is the only thing in the pipeline that writes one.
            agent { label 'docker' }
            steps {
                checkoutRepo()
                publishManifest('base')
            }
            post {
                always {
                    cleanWs()
                }
            }
        }

        stage('Agents') {
            // Parallel across architectures, sequential across agents — deliberately not one branch
            // per agent.
            //
            // Everything below the Jenkins workspace is shared per machine: one Docker daemon, one
            // buildx builder named `mybuilder`, one build cache. One branch per agent landing on the same
            // node would each create and then remove that builder underneath the others, and
            // docker_cleanup.sh would prune a cache the neighbours are still reading. Two branches,
            // each looping over the agents, keep the whole tool matrix on two machines with nothing
            // shared between concurrent builds.
            //
            // The cost is wall-clock time, and it is small: every agent image is a thin layer on a
            // base that is already built and pushed.
            //
            // The loop is generated from env.AGENT_IDS, so adding a tool needs no change here.
            parallel {
                stage('agents amd64') {
                    agent { label 'docker' }
                    steps {
                        checkoutRepo()
                        script {
                            env.AGENT_IDS.split(' ').findAll { it }.each { id ->
                                buildImage(id, 'amd64', 'linux/amd64')
                            }
                        }
                    }
                    post {
                        always {
                            sh './scripts/docker_cleanup.sh'
                            cleanWs()
                        }
                    }
                }
                stage('agents arm64') {
                    agent { label 'oracle_docker' }
                    steps {
                        checkoutRepo()
                        script {
                            env.AGENT_IDS.split(' ').findAll { it }.each { id ->
                                buildImage(id, 'arm64', 'linux/arm64')
                            }
                        }
                    }
                    post {
                        always {
                            sh './scripts/docker_cleanup.sh'
                            cleanWs()
                        }
                    }
                }
            }
        }

        stage('Agent manifests') {
            // Reached only when every agent image pushed on both architectures: a failed branch
            // fails the parallel stage and this never runs, so a broken tool cannot end up as a
            // published tag that silently serves one architecture.
            //
            // Any agent will do — this talks to the registry and builds nothing.
            agent { label 'docker' }
            steps {
                checkoutRepo()
                script {
                    env.AGENT_IDS.split(' ').findAll { it }.each { id ->
                        publishManifest(id)
                    }
                }
            }
            post {
                always {
                    cleanWs()
                }
            }
        }
    }

    post {
        always {
            // No cleanWs here: with `agent none` this block has no workspace to clean, and asking
            // for one fails the build after everything already succeeded. Each stage cleans its own.
            discordSend result: currentBuild.currentResult,
                description: env.GIT_URL,
                link: env.BUILD_URL,
                title: JOB_NAME,
                webhookURL: DISCORD_WEBHOOK
        }
    }
}
