#!/usr/bin/env bats
# shellcheck, exec bits, and the small consistency checks that catch a stale file before a user does.

load helper

all_shell_files() {
    printf '%s\n' \
        "${REPO_ROOT}/bin/docker-code" \
        "${REPO_ROOT}/install.sh"
    find "${REPO_ROOT}/lib" "${REPO_ROOT}/image" "${REPO_ROOT}/scripts" -name '*.sh' | sort
}

@test "shellcheck passes on every shell file" {
    while IFS= read -r file; do
        run shellcheck --external-sources --source-path="${REPO_ROOT}" "${file}"
        [ "${status}" -eq 0 ] || {
            echo "shellcheck failed for ${file}:"
            echo "${output}"
            return 1
        }
    done <<EOF
$(all_shell_files)
EOF
}

@test "everything meant to be executed is executable" {
    for file in "${REPO_ROOT}/bin/docker-code" "${REPO_ROOT}/install.sh" \
                "${REPO_ROOT}"/image/*.sh "${REPO_ROOT}"/scripts/*.sh; do
        [ -x "${file}" ] || { echo "${file} is not executable"; return 1; }
    done
}

@test "the sourced libraries are not executable, so nobody runs one by mistake" {
    for file in "${REPO_ROOT}"/lib/*.sh; do
        [ ! -x "${file}" ] || { echo "${file} is executable but is meant to be sourced"; return 1; }
    done
}

@test "every seeded default is valid for its format" {
    for file in $(find "${REPO_ROOT}/agents" -name '*.json'); do
        run jq empty "${file}"
        [ "${status}" -eq 0 ] || { echo "${file} is not valid JSON: ${output}"; return 1; }
    done
}

@test "a seeded default lands somewhere the tool will look" {
    # The defaults directory mirrors the home directory, so a file at defaults/foo would end up as
    # ~/foo — almost certainly not what was meant.
    for id in $(all_agent_ids); do
        dir="${REPO_ROOT}/agents/${id}/defaults"
        [ -d "${dir}" ] || continue
        for file in $(find "${dir}" -type f); do
            rel="${file#"${dir}"/}"
            case "${rel}" in
                */*) ;;
                .*) ;;
                *) echo "agents/${id}/defaults/${rel} would be seeded as ~/${rel}"; return 1 ;;
            esac
        done
    done
}

@test "every knob the README documents really has a per-agent form" {
    # The README promises DOCKER_CODE_<AGENT>_<KNOB> for every knob in its table. A knob read
    # straight out of the environment instead of through agent_knob ignores that spelling silently —
    # which is what DOCKER_CODE_CLAUDE_YOLO=1 did for a while: nothing at all.
    #
    # Two are global on purpose: DRY_RUN is the test seam and HOME is the root of the state
    # directory, shared by every agent by definition.
    global_only=" DRY_RUN HOME "

    knobs="$(sed -n '/^## Configuration/,/^---$/p' "${REPO_ROOT}/README.md" |
        grep -oE '`[A-Z_]+=' | tr -d '`=' | sort -u)"
    [ -n "${knobs}" ]

    for knob in ${knobs}; do
        case "${global_only}" in
            *" ${knob} "*) continue ;;
        esac
        grep -q "agent_knob ${knob} " "${REPO_ROOT}/bin/docker-code" ||
            grep -q "agent_knob ${knob}\"" "${REPO_ROOT}/bin/docker-code" ||
            grep -qE "for knob in .*\b${knob}\b" "${REPO_ROOT}/bin/docker-code" || {
                echo "README documents ${knob}, but bin/docker-code never resolves it with agent_knob"
                echo "so DOCKER_CODE_<AGENT>_${knob} would be ignored"
                return 1
            }
    done
}

@test "the files the docs point at exist" {
    for doc in README.md AGENTS.md ai/adding-an-agent.md docs/LOCAL-MODELS.md docs/REGISTRY.md \
               docs/EGRESS.md; do
        [ -f "${REPO_ROOT}/${doc}" ] || { echo "${doc} is missing"; return 1; }
    done
}

@test "tool-specific AI instruction files resolve to the canonical content" {
    for doc in CLAUDE.md GEMINI.md QWEN.md; do
        # Docker COPY dereferences source links in the test image. In a checkout, verify the link;
        # in that image, verify the resulting file is still byte-for-byte canonical.
        if [ -L "${REPO_ROOT}/${doc}" ]; then
            [ "$(readlink "${REPO_ROOT}/${doc}")" = "AGENTS.md" ] || {
                echo "${doc} does not link to AGENTS.md"; return 1
            }
        else
            cmp -s "${REPO_ROOT}/${doc}" "${REPO_ROOT}/AGENTS.md" || {
                echo "${doc} differs from AGENTS.md"; return 1
            }
        fi
    done
}

@test "the help text names only commands that exist" {
    run "${REPO_ROOT}/bin/docker-code" help
    [ "${status}" -eq 0 ]
    for cmd in list build update models registry doctor; do
        [[ "${output}" == *"${cmd}"* ]] || { echo "help does not mention ${cmd}"; return 1; }
        grep -q "^    ${cmd}[)|]" "${REPO_ROOT}/bin/docker-code" ||
            grep -q "^    ${cmd}|" "${REPO_ROOT}/bin/docker-code" || {
                echo "help mentions ${cmd} but the dispatcher has no branch for it"; return 1
            }
    done
}

@test "every wrapper the help text names is one an agent actually claims" {
    # The direction that matters: an example left behind after a tool was renamed or removed sends
    # the reader to a command that does not exist.
    run "${REPO_ROOT}/bin/docker-code" help
    [ "${status}" -eq 0 ]

    # A leading [a-z0-9] so a placeholder like <agent>-docker does not decompose into "-docker".
    names="$(printf '%s\n' "${output}" | tr -c 'a-z0-9-' '\n' | grep -E '^[a-z0-9][a-z0-9-]*-docker$' | sort -u)"
    for word in ${names}; do
        run bash -c ". '${REPO_ROOT}/lib/agents.sh'; agent_for_wrapper '${word}'"
        [ "${status}" -eq 0 ] || {
            echo "the help text names ${word}, which no agent claims"; return 1
        }
    done
}

@test "the installer never uses sudo and never edits a shell startup file" {
    # Both are promises made in install.sh's own header, and both are the kind of thing that gets
    # added in a hurry when a PATH problem shows up — --system in particular, which does write to
    # /opt and /usr/local/bin and asks the caller to be root rather than arranging that itself.
    #
    # Written as if-blocks, not as `! grep`: errexit does not act on an inverted command, so a bare
    # `! grep -q ...` line cannot fail a bats test unless it happens to be the last one. The first
    # of these two assertions was dead for exactly that reason.
    if grep -vE '^[[:space:]]*#' "${REPO_ROOT}/install.sh" | grep -q 'sudo'; then
        echo "install.sh calls sudo:"
        grep -nE 'sudo' "${REPO_ROOT}/install.sh" | grep -vE '^[0-9]+:[[:space:]]*#'
        return 1
    fi
    if grep -qE '>>?\s*"?\$\{?HOME\}?/\.(bashrc|zshrc|profile)' "${REPO_ROOT}/install.sh"; then
        echo "install.sh writes to a shell startup file"
        return 1
    fi
}

@test "the one-line installer in the README is the URL the installer names for itself" {
    # The README's first command and the usage line install.sh prints when it was piped into a shell
    # are the same URL written twice, and a moved default ref would only be noticed in one of them.
    repo="$(sed -n 's/^REPO="${DOCKER_CODE_REPO:-\(.*\)}"$/\1/p' "${REPO_ROOT}/install.sh")"
    ref="$(sed -n 's/^REF="${DOCKER_CODE_REF:-\(.*\)}"$/\1/p' "${REPO_ROOT}/install.sh")"
    [ -n "${repo}" ] && [ -n "${ref}" ]

    grep -q 'raw\.githubusercontent\.com/${REPO}/${REF}/install\.sh' "${REPO_ROOT}/install.sh" || {
        echo "install.sh does not build its own name from REPO and REF"; return 1
    }
    grep -qF "curl -fsSL https://raw.githubusercontent.com/${repo}/${ref}/install.sh | bash" \
        "${REPO_ROOT}/README.md" || {
        echo "the README does not carry the one-liner for ${repo}@${ref}"; return 1
    }
}

@test "--system installs where the README says it does, and yields to an explicit path" {
    # --help exits inside the option loop, so the usage text reports the paths as they stand at that
    # point — which is how the resolution can be checked without writing to /opt on the machine
    # running the suite.
    prefix="$(sed -n 's/^SYSTEM_PREFIX=//p' "${REPO_ROOT}/install.sh")"
    dir="$(sed -n 's/^SYSTEM_INSTALL_DIR=//p' "${REPO_ROOT}/install.sh")"
    [ -n "${prefix}" ] && [ -n "${dir}" ]

    run "${REPO_ROOT}/install.sh" --system --help
    [ "${status}" -eq 0 ]
    printf '%s\n' "${output}" | grep -E '^\s+--prefix DIR' | grep -qF "${prefix}"
    printf '%s\n' "${output}" | grep -E '^\s+--dir DIR' | grep -qF "${dir}"

    for path in "${prefix}" "${dir}"; do
        grep -qF "${path}" "${REPO_ROOT}/README.md" || {
            echo "--system installs into ${path}, which the README does not mention"; return 1
        }
    done

    # A --prefix or --dir after --system is the more specific instruction and has to win, or
    # `docker-code self-update` on a system installation would relocate it on the next run.
    run "${REPO_ROOT}/install.sh" --system --prefix /tmp/dc-prefix --dir /tmp/dc-dir --help
    [ "${status}" -eq 0 ]
    printf '%s\n' "${output}" | grep -E '^\s+--prefix DIR' | grep -qF /tmp/dc-prefix
    printf '%s\n' "${output}" | grep -E '^\s+--dir DIR' | grep -qF /tmp/dc-dir
}

@test "--system refuses rather than half-installing when it may not write there" {
    # The failure mode it exists for: a copy into /opt that stops partway and a "Permission denied"
    # for every wrapper after it. The check runs before anything is created, so the tree stays absent.
    if [ "$(id -u)" = "0" ]; then
        command -v setpriv >/dev/null || skip "needs setpriv to drop root"
        run setpriv --reuid=65534 --regid=65534 --clear-groups \
            bash "${REPO_ROOT}/install.sh" --system --local "${REPO_ROOT}"
    else
        run bash "${REPO_ROOT}/install.sh" --system --local "${REPO_ROOT}"
    fi

    [ "${status}" -ne 0 ]
    [[ "${output}" == *"root"* ]] || {
        echo "the refusal does not say what is missing:"; echo "${output}"; return 1
    }

    # The other way into the same directory: `docker-code self-update` on a --system installation
    # passes the recorded --prefix and --dir rather than --system, and it is normally the user who
    # types it, not root.
    if [ "$(id -u)" = "0" ]; then
        run setpriv --reuid=65534 --regid=65534 --clear-groups \
            bash "${REPO_ROOT}/install.sh" --local "${REPO_ROOT}" \
            --prefix /opt/docker-code --dir /usr/local/bin
    else
        run bash "${REPO_ROOT}/install.sh" --local "${REPO_ROOT}" \
            --prefix /opt/docker-code --dir /usr/local/bin
    fi
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"root"* ]] || {
        echo "the refusal does not say what is missing:"; echo "${output}"; return 1
    }
}

@test "the installer validates a download before installing it" {
    grep -q "head -n 1.*grep -q '\^#!'" "${REPO_ROOT}/install.sh"
    grep -q 'DOCKER_CODE_HOME' "${REPO_ROOT}/install.sh"
}

@test "an installation carries the installer and a record of where it came from" {
    # Without both, `docker-code self-update` has nothing to run and nothing to run it against —
    # and would have to guess, which for a --local install means silently pulling from GitHub over
    # a copy somebody made from the checkout they are working in.
    grep -q 'cp "${SOURCE}/install.sh" "${PREFIX}/install.sh"' "${REPO_ROOT}/install.sh"
    grep -q '\.install-source' "${REPO_ROOT}/install.sh"
    grep -q '\.install-source' "${REPO_ROOT}/bin/docker-code"
}

@test "self-update replaces this process before the installer deletes it" {
    # The installer's first act is to remove the prefix, which holds the running script. Bash reads
    # a script incrementally, so a copy plus exec is what keeps that from truncating mid-command.
    block="$(sed -n '/^cmd_self_update/,/^}/p' "${REPO_ROOT}/bin/docker-code")"
    [[ "${block}" == *"mktemp"* ]]
    [[ "${block}" == *"exec bash"* ]]
}

@test "self-update from a checkout explains itself instead of pretending to work" {
    run "${REPO_ROOT}/bin/docker-code" self-update
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"checkout, not an installation"* ]]
    [[ "${output}" == *"git -C ${REPO_ROOT} pull"* ]]
}

@test "the two update commands are distinguishable from the help alone" {
    run "${REPO_ROOT}/bin/docker-code" help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"update"* ]]
    [[ "${output}" == *"self-update"* ]]
    # `update` must say it means images, or it reads as the one that updates the command.
    printf '%s\n' "${output}" | grep -E '^\s+docker-code update' | grep -qi 'image'
}

@test "the installer derives wrapper names from the tree, not from a list of its own" {
    grep -q 'AGENT_WRAPPER' "${REPO_ROOT}/install.sh"
    for id in $(all_agent_ids); do
        wrapper="$(agent_field "${id}" AGENT_WRAPPER)"
        grep -q "${wrapper}" "${REPO_ROOT}/install.sh" && {
            echo "install.sh hard-codes ${wrapper}; it should read agents/*/agent.env"; return 1
        }
    done
    return 0
}

@test "the installer never pipes its wrapper list into a reader that stops early" {
    # head closes the pipe after the first line while wrapper_names is still printf-ing the other ten.
    # printf is a bash builtin, so where sed or find would die quietly on SIGPIPE, it reports the
    # failed write instead — and the last line of a successful install was
    #     install.sh: line 84: printf: write error: Broken pipe
    ! grep -qE 'wrapper_names[^|]*\|[[:space:]]*head' "${REPO_ROOT}/install.sh" || {
        echo "install.sh pipes wrapper_names into head; take the first line after the fact instead"
        return 1
    }
}

@test "a successful install says nothing on stderr, even with SIGPIPE ignored" {
    # The condition the report came from. With SIGPIPE at its default the writer is killed silently
    # and the bug does not reproduce — which is why it survived to a release. Ignoring SIGPIPE makes
    # write() return EPIPE instead, which is what the reporting shell had inherited.
    run bash -c "
        trap '' PIPE
        INSTALL_DIR='${BATS_TEST_TMPDIR}/bin' DOCKER_CODE_PREFIX='${BATS_TEST_TMPDIR}/share' \
            bash '${REPO_ROOT}/install.sh' --local '${REPO_ROOT}' 2>&1 >/dev/null
    "
    [ "${status}" -eq 0 ]
    [ -z "${output}" ] || {
        echo "the installer wrote to stderr:"
        echo "${output}"
        return 1
    }
}

@test "the installer sends you to the published images, not to a local build" {
    # `docker run` pulls the image the first time an agent starts, so a fresh install is one command
    # away from working. Telling someone to build nine images first puts an hour in front of the
    # thing they came to do, and building is the exception rather than the normal path.
    # Only what is printed. The comment above it names the command it is deliberately not using, and
    # matching that would make the test fail on its own explanation.
    block="$(sed -n '/case ":${PATH}:"/,/^esac$/p' "${REPO_ROOT}/install.sh" |
        grep '^[[:space:]]*echo')"
    [ -n "${block}" ]
    [[ "${block}" != *"docker-code build"* ]] || {
        echo "the installer's closing hint still points at docker-code build:"
        printf '%s\n' "${block}"
        return 1
    }
}

@test "fetching goes through git, not GitHub's throttled archive endpoints" {
    # GitHub throttles codeload and raw.githubusercontent.com separately from the rest of the API and
    # considerably harder. A self-update died on
    #     curl: (56) The requested URL returned error: 429
    # at a moment when api.github.com reported a full quota and cloning worked fine, so the archive
    # path is not a shortcut worth keeping next to a clone.
    block="$(sed -n '/^# Fetch$/,/^# Install$/p' "${REPO_ROOT}/install.sh")"
    [ -n "${block}" ]
    [[ "${block}" == *"git clone"* ]]

    for endpoint in codeload raw.githubusercontent.com tar.gz; do
        [[ "${block}" != *"${endpoint}"* ]] || {
            echo "the fetch still reaches for ${endpoint}, which is the throttled path"
            return 1
        }
    done
}

@test "a pinned commit sha still installs, though --branch refuses one" {
    # git clone --branch takes a branch or a tag only, so DOCKER_CODE_REF=<sha> has to fall through
    # to a full clone and an explicit checkout rather than failing the install.
    block="$(sed -n '/^# Fetch$/,/^# Install$/p' "${REPO_ROOT}/install.sh")"
    [[ "${block}" == *"checkout"* ]] || {
        echo "there is no path for a ref that is not a branch or tag"
        return 1
    }
}

@test "a missing git says so, and names the way out that needs no network" {
    block="$(sed -n '/^# Fetch$/,/^# Install$/p' "${REPO_ROOT}/install.sh")"
    [[ "${block}" == *"git is required"* ]]
    [[ "${block}" == *"--local"* ]]
}

@test "the two container-side agent.env parsers have not drifted apart" {
    # image/launch.sh and image/init-firewall.sh each carry their own copy, because neither can source
    # lib/agents.sh: the container has one agent.env at a fixed path and none of the host's layout.
    # Two copies is the same trade as COMMON_DOMAINS in those two files — allowed, but pinned here.
    a="$(sed -n '/^agent_get()/,/^}/p' "${REPO_ROOT}/image/launch.sh")"
    b="$(sed -n '/^agent_get()/,/^}/p' "${REPO_ROOT}/image/init-firewall.sh")"
    [ -n "${a}" ] && [ -n "${b}" ]
    [ "${a}" = "${b}" ] || {
        echo "the two agent_get copies differ:"
        diff <(printf '%s\n' "${a}") <(printf '%s\n' "${b}") || true
        return 1
    }
}

@test "the container parser reads agent.env the same way the host validates it" {
    # The host accepts an agent.env and the container acts on it, so a disagreement is invisible until
    # a session starts: `AGENT_BIN=vibe  # the binary` passed every check here and then failed at exec
    # with a command name that had a comment in it. Each line below is one rule of the format.
    env_file="${BATS_TEST_TMPDIR}/agent.env"
    cat >"${env_file}" <<'EOF'
AGENT_ID=demo
AGENT_BIN=vibe   # a bare value ends at the first hash
AGENT_TITLE="Demo # inside quotes it is kept"
AGENT_HOSTNAME='single # quoted too'
AGENT_DOMAINS="a.example b.example \
c.example"
AGENT_NOTE=bare value with spaces
EOF

    for key in AGENT_ID AGENT_BIN AGENT_TITLE AGENT_HOSTNAME AGENT_DOMAINS AGENT_NOTE; do
        host="$(bash -c ". '${REPO_ROOT}/lib/agents.sh'; agent_parse_file '${env_file}' >/dev/null; \
                         eval \"printf '%s' \\\"\\\${${key}:-}\\\"\"")"
        container="$(bash -c ". <(sed -n '/^agent_get()/,/^}/p' '${REPO_ROOT}/image/launch.sh'); \
                              AGENT_ENV_FILE='${env_file}'; agent_get ${key}")"
        [ "${host}" = "${container}" ] || {
            echo "${key}: host reads [${host}], the container reads [${container}]"
            return 1
        }
    done
}

@test "the installer refuses a prefix it would delete" {
    # The install replaces the prefix wholesale, so `--prefix ~/.local` — one keystroke from
    # ~/.local/share/docker-code — used to remove that directory and everything in it, and
    # .install-source then made self-update repeat it.
    home="${BATS_TEST_TMPDIR}/home"
    mkdir -p "${home}/.local"
    : >"${home}/.local/precious"

    run env HOME="${home}" "${REPO_ROOT}/install.sh" --local "${REPO_ROOT}" \
        --prefix "${home}/.local" --dir "${BATS_TEST_TMPDIR}/bin"
    [ "${status}" -ne 0 ]
    [ -f "${home}/.local/precious" ] || {
        echo "the installer deleted a directory that was not its own"
        return 1
    }

    run env HOME="${home}" "${REPO_ROOT}/install.sh" --local "${REPO_ROOT}" \
        --prefix "${home}" --dir "${BATS_TEST_TMPDIR}/bin"
    [ "${status}" -ne 0 ]
    [ -d "${home}" ]
}

@test "the installer refuses to install over a checkout" {
    # The hardest one to catch, because a checkout and an installation both hold bin/docker-code —
    # so the "does it look like ours" test says yes and the rm -rf takes the working tree, .git and
    # anything uncommitted with it. README.md opens with `git clone … && ./install.sh --local`, so
    # naming that same directory as the prefix is a short step from what people actually type.
    home="${BATS_TEST_TMPDIR}/home"
    checkout="${BATS_TEST_TMPDIR}/checkout"
    mkdir -p "${home}" "${checkout}/bin" "${checkout}/.git"
    : >"${checkout}/bin/docker-code"
    : >"${checkout}/uncommitted"

    run env HOME="${home}" "${REPO_ROOT}/install.sh" --local "${REPO_ROOT}" \
        --prefix "${checkout}" --dir "${BATS_TEST_TMPDIR}/bin"
    [ "${status}" -ne 0 ]
    [ -d "${checkout}/.git" ] || {
        echo "the installer deleted a git working tree"
        return 1
    }
    [ -f "${checkout}/uncommitted" ]
}

@test "the installer refuses a prefix that contains the source it installs from" {
    # The prefix is emptied before the copy, so this would delete the tree being read from.
    home="${BATS_TEST_TMPDIR}/home"
    box="${BATS_TEST_TMPDIR}/box"
    mkdir -p "${home}" "${box}/src"
    cp -R "${REPO_ROOT}/bin" "${REPO_ROOT}/lib" "${REPO_ROOT}/agents" "${box}/src/"

    run env HOME="${home}" "${REPO_ROOT}/install.sh" --local "${box}/src" \
        --prefix "${box}" --dir "${BATS_TEST_TMPDIR}/bin"
    [ "${status}" -ne 0 ]
    [ -d "${box}/src/bin" ]
}

@test "a relative prefix is refused, since self-update re-runs from elsewhere" {
    run env HOME="${BATS_TEST_TMPDIR}/home" "${REPO_ROOT}/install.sh" --local "${REPO_ROOT}" \
        --prefix ./relative --dir "${BATS_TEST_TMPDIR}/bin"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"absolute"* ]]
}

@test "the guard does not stand in the way of installing or reinstalling" {
    # The other half: a prefix that does not exist yet is fine, and so is one holding a previous
    # installation — which is the normal case every update goes through.
    home="${BATS_TEST_TMPDIR}/home"
    prefix="${home}/.local/share/docker-code"
    mkdir -p "${home}"

    for _ in 1 2; do
        run env HOME="${home}" "${REPO_ROOT}/install.sh" --local "${REPO_ROOT}" \
            --prefix "${prefix}" --dir "${BATS_TEST_TMPDIR}/bin"
        [ "${status}" -eq 0 ] || {
            echo "${output}"
            return 1
        }
    done
    [ -f "${prefix}/bin/docker-code" ]
}

@test "the global settings table documents variables that really are global" {
    # The per-agent table has its own check above. This is the other half: anything listed as global
    # must not be resolved with agent_knob, or the README would be denying a per-agent form that
    # actually works — and it must be read somewhere, or the table documents nothing.
    vars="$(sed -n '/^## Global settings/,/^## Environment variables/p' "${REPO_ROOT}/README.md" |
        grep -oE '`DOCKER_CODE_[A-Z_]+`' | tr -d '`' | sort -u)"
    [ -n "${vars}" ]

    for var in ${vars}; do
        grep -rq -- "${var}" "${REPO_ROOT}"/lib/*.sh "${REPO_ROOT}/bin/docker-code" || {
            echo "README documents ${var}, but nothing reads it"
            return 1
        }
        knob="${var#DOCKER_CODE_}"
        if grep -qE "agent_knob ${knob}[ \"]" "${REPO_ROOT}/bin/docker-code"; then
            echo "${var} is resolved with agent_knob, so it does have a per-agent form"
            echo "and belongs in the Configuration table instead of the global one"
            return 1
        fi
    done
}

@test "the documented network ranges are the ones the code defaults to" {
    # The whole point of pinning a range is that it can be named in a route or a firewall exception,
    # so a README that says 172.30.30.0/24 while the code says something else is worse than no
    # documentation at all.
    for pair in "DOCKER_CODE_REGISTRY_SUBNET:lib/mirror.sh" "DOCKER_CODE_MODELS_SUBNET:lib/models.sh"; do
        var="${pair%%:*}"
        file="${pair##*:}"

        code="$(sed -n "s/.*\${${var}-\([^}]*\)}.*/\1/p" "${REPO_ROOT}/${file}" | head -n 1)"
        [ -n "${code}" ] || {
            echo "${var} is no longer read with a default in ${file}"
            return 1
        }

        grep -qF "| \`${var}\` | \`${code}\` |" "${REPO_ROOT}/README.md" || {
            echo "${file} defaults ${var} to ${code}, which is not what the README's table says:"
            grep -F "\`${var}\`" "${REPO_ROOT}/README.md" || true
            return 1
        }
    done
}

@test "the project states a licence, and the README points at it" {
    # Without one, default copyright applies and nobody may legally use, fork or redistribute this —
    # while README.md's first instruction is to clone it and the images are published for anyone to
    # pull.
    [ -f "${REPO_ROOT}/LICENSE" ]
    grep -q 'MIT License' "${REPO_ROOT}/LICENSE"
    grep -qE 'Copyright \(c\) [0-9]{4}' "${REPO_ROOT}/LICENSE"
    grep -q '(LICENSE)' "${REPO_ROOT}/README.md"
}

@test "doctor reports the range every docker-code network is running on" {
    # A range that collides with the host's LAN is a first-class failure here and three settings
    # govern it, so there has to be one command that says what is actually in effect. Finding out
    # used to mean `docker network ls` piped into `docker network inspect` by hand.
    block="$(sed -n '/^doctor_networks()/,/^}/p' "${REPO_ROOT}/bin/docker-code")"
    [ -n "${block}" ]

    # Every network docker-code can create has to be reachable from it.
    for want in MIRROR_NETWORK MODELS_NETWORK EGRESS_OUT_NETWORK egress_network EGRESS_SERVICES_ID; do
        [[ "${block}" == *"${want}"* ]] || {
            echo "doctor_networks never looks at ${want}"
            return 1
        }
    done

    # And it reports the running subnet, not the configured one — they come apart exactly when
    # someone is trying to work out why a setting appears to do nothing.
    row="$(sed -n '/^doctor_network_row()/,/^}/p' "${REPO_ROOT}/bin/docker-code")"
    [[ "${row}" == *"docker network inspect"*".IPAM.Config"* ]]
    [[ "${row}" == *"applies once this network is recreated"* ]]
}
