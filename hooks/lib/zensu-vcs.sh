#!/bin/bash

_zensu_vcs_remote_url() {
  if [ -n "${ZENSU_VCS_REMOTE:-}" ]; then
    printf '%s' "$ZENSU_VCS_REMOTE"
    return 0
  fi
  local repo="${1:-.}"
  command -v git >/dev/null 2>&1 || return 0
  local rn
  rn="$(git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
  rn="${rn%%/*}"
  [ -n "$rn" ] || rn="origin"
  git -C "$repo" remote get-url "$rn" 2>/dev/null
}

_zensu_vcs_split_url() {
  local url="${1:-}"
  if ! command -v node >/dev/null 2>&1; then
    printf '\t'
    return 0
  fi
  # Host capture excludes `@` so a userinfo-authority (`a@b@127.0.0.1`) cannot be smuggled past the private-IP guard (SSRF).
  U="$url" node -e '
    var u=(process.env.U||"").trim().replace(/\.git$/,"");
    var host="",path="",m;
    if(m=u.match(/^[A-Za-z][A-Za-z0-9+.-]*:\/\/([^@\/]*@)?([^\/:@]+)(?::[0-9]+)?\/(.*)$/)){host=m[2];path=m[3];}
    else if(m=u.match(/^([^@\/]*@)?([^\/:@]+):(.*)$/)){host=m[2];path=m[3];}
    process.stdout.write(host+"\t"+path);
  '
}

_zensu_vcs_classify_host() {
  case "${1:-}" in
    github.com) printf 'github cloud' ;;
    gitlab.com) printf 'gitlab cloud' ;;
    *)          printf '' ;;
  esac
}

_zensu_vcs_probeable_host() {
  local h="${1:-}"
  [ -n "$h" ] || return 1
  # Normalize for the loopback denylist (bash 3.2 lacks ${h,,}): lowercase + strip trailing FQDN dots, so FOO.LOCALHOST / localhost. / localhost.. deny like localhost (DNS is case-insensitive; curl uses the original $h).
  local hl; hl="$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')"
  while [ "$hl" != "${hl%.}" ]; do hl="${hl%.}"; done
  case "$hl" in
    *:*) return 1 ;;
    localhost|localhost.localdomain|*.local|*.localhost|*.internal) return 1 ;;
    0.*|127.*|10.*|192.168.*|169.254.*|255.255.255.255) return 1 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 1 ;;
  esac
  case "$hl" in
    *[!0-9.]*) : ;;
    *.*.*.*)   return 1 ;;
    *)         return 1 ;;
  esac
  case "$hl" in
    *.*) return 0 ;;
    *)   return 1 ;;
  esac
}

_zensu_vcs_safe_ip() {
  command -v node >/dev/null 2>&1 || { printf ''; return 0; }
  H="${1:-}" FAKE="${ZENSU_VCS_FAKE_RESOLVE:-}" TEST="${ZENSU_VCS_TEST:-}" node -e '
    var host=(process.env.H||"").trim().toLowerCase();
    var test=process.env.TEST==="1";
    function isPrivate(ip){
      ip=String(ip).trim().toLowerCase();
      var m=ip.match(/^::(?:ffff:)?(\d+\.\d+\.\d+\.\d+)$/);
      if(m){ip=m[1];}
      var v4=ip.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
      if(v4){
        var a=+v4[1],b=+v4[2],c=+v4[3],d=+v4[4];
        if(a>255||b>255||c>255||d>255){return true;}
        if(a===0||a===10||a===127){return true;}
        if(a===169&&b===254){return true;}
        if(a===172&&b>=16&&b<=31){return true;}
        if(a===192&&b===168){return true;}
        if(a===100&&b>=64&&b<=127){return true;}
        if(a>=224){return true;}
        return false;
      }
      if(ip.indexOf(":")<0){return true;}
      var em=ip.match(/(?:^|:)(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/);
      if(em){return isPrivate(em[1]);}
      if(/^64:ff9b:/.test(ip)||/^2002:/.test(ip)){return true;}
      if(/^[23]/.test(ip)){return false;}
      return true;
    }
    function pick(addrs){
      if(!addrs||!addrs.length){return "";}
      for(var i=0;i<addrs.length;i++){if(isPrivate(addrs[i])){return "";}}
      return addrs[0];
    }
    if(test){
      var map={},s=process.env.FAKE||"";
      s.split(";").forEach(function(p){var i=p.indexOf("=");if(i>0){map[p.slice(0,i).trim().toLowerCase()]=p.slice(i+1).split(",").map(function(x){return x.trim();}).filter(Boolean);}});
      process.stdout.write(pick(map[host]||[]));
    } else {
      var done=false,t=setTimeout(function(){if(!done){done=true;process.stdout.write("");process.exit(0);}},2000);
      require("dns").lookup(host,{all:true},function(e,addrs){
        if(done){return;}
        done=true;clearTimeout(t);
        if(e||!addrs){process.stdout.write("");return;}
        process.stdout.write(pick(addrs.map(function(a){return a.address;})));
      });
    }
  '
}

_zensu_vcs_http_present() {
  command -v curl >/dev/null 2>&1 || return 1
  local host="${1:-}" path="${2:-}" ip="${3:-}"
  [ -n "$ip" ] || return 1
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 --resolve "${host}:443:${ip}" "https://${host}${path}" 2>/dev/null)"
  case "$code" in
    200|401|403) return 0 ;;
    *)           return 1 ;;
  esac
}

_zensu_vcs_probe() {
  if [ "${ZENSU_VCS_TEST:-}" = "1" ] && [ -n "${ZENSU_VCS_PROBE_RESULT:-}" ]; then
    printf '%s' "$ZENSU_VCS_PROBE_RESULT"
    return 0
  fi
  # Offline mode: skip the network probe entirely (callers that must not emit
  # outbound HTTP — e.g. /zensu:doctor — set this). Detection falls back to the
  # CI-file marker / unknown tiebreak instead of curl-ing the remote's host.
  if [ "${ZENSU_VCS_NO_PROBE:-}" = "1" ]; then
    printf 'none'
    return 0
  fi
  local host="${1:-}"
  _zensu_vcs_probeable_host "$host" || { printf 'none'; return 0; }
  # Connection-time IP pinning: resolve the host, reject if ANY address is private/loopback/link-local (defeats round-robin rebinding), then curl --resolve to the checked IP (defeats the check-vs-connect TOCTOU). Fail-closed: no safe IP (private / unresolvable / no node) -> do not probe.
  local ip; ip="$(_zensu_vcs_safe_ip "$host")"
  [ -n "$ip" ] || { printf 'none'; return 0; }
  if _zensu_vcs_http_present "$host" "/api/v4/version" "$ip"; then
    printf 'gitlab'
  elif _zensu_vcs_http_present "$host" "/api/v3/meta" "$ip"; then
    printf 'github-enterprise'
  else
    printf 'none'
  fi
}

_zensu_vcs_marker() {
  local repo="${1:-.}"
  if [ -f "$repo/.gitlab-ci.yml" ]; then
    printf 'gitlab'
  elif [ -d "$repo/.github/workflows" ]; then
    printf 'github'
  else
    printf 'none'
  fi
}

_zensu_vcs_api_base() {
  local host="${3:-}"
  case "${1:-}:${2:-}" in
    github:cloud)      printf 'https://api.github.com' ;;
    github:enterprise) [ -n "$host" ] && printf 'https://%s/api/v3' "$host" || printf '' ;;
    gitlab:cloud)      printf 'https://gitlab.com/api/v4' ;;
    gitlab:selfhosted) [ -n "$host" ] && printf 'https://%s/api/v4' "$host" || printf '' ;;
    *)                 printf '' ;;
  esac
}

_zensu_vcs_repo_id() {
  local provider="${1:-}" path="${2:-}"
  [ -n "$path" ] || { printf ''; return 0; }
  case "$provider" in
    gitlab)
      if command -v node >/dev/null 2>&1; then
        P="$path" node -e 'process.stdout.write(encodeURIComponent(process.env.P||""))'
      else
        printf ''
      fi
      ;;
    github)
      printf '%s' "$path"
      ;;
    *)
      printf ''
      ;;
  esac
}

_zensu_vcs_cli_for() {
  case "${1:-}" in
    github) printf 'gh' ;;
    gitlab) printf 'glab' ;;
    *)      printf '' ;;
  esac
}

_zensu_vcs_auth_state() {
  if [ "${ZENSU_VCS_TEST:-}" = "1" ] && [ -n "${ZENSU_VCS_FAKE_AUTH:-}" ]; then
    printf '%s' "$ZENSU_VCS_FAKE_AUTH"
    return 0
  fi
  local cli="${1:-}"
  [ -n "$cli" ] || { printf 'missing'; return 0; }
  command -v "$cli" >/dev/null 2>&1 || { printf 'missing'; return 0; }
  if "$cli" auth status >/dev/null 2>&1; then
    printf 'ready'
  else
    printf 'unauthed'
  fi
}

_zensu_vcs_detect() {
  local repo="." o_provider="${ZENSU_VCS_PROVIDER:-}" o_apibase="${ZENSU_VCS_API_BASE:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --provider) o_provider="${2:-}"; shift ;;
      --api-base) o_apibase="${2:-}"; shift ;;
      --repo)     repo="${2:-.}"; shift ;;
      *) ;;
    esac
    shift
  done

  local url host path
  url="$(_zensu_vcs_remote_url "$repo")"
  IFS="$(printf '\t')" read -r host path <<EOF
$(_zensu_vcs_split_url "$url")
EOF

  local provider="" edition=""
  if [ -n "$o_provider" ]; then
    provider="$o_provider"
    case "$host" in
      github.com|gitlab.com|"") edition="cloud" ;;
      *) if [ "$provider" = "gitlab" ]; then edition="selfhosted"; else edition="enterprise"; fi ;;
    esac
  elif [ -z "$host" ]; then
    provider="unknown"; edition=""
  else
    read -r provider edition <<EOF
$(_zensu_vcs_classify_host "$host")
EOF
    if [ -z "$provider" ]; then
      case "$(_zensu_vcs_probe "$host")" in
        gitlab)            provider="gitlab"; edition="selfhosted" ;;
        github-enterprise) provider="github"; edition="enterprise" ;;
        *)
          case "$(_zensu_vcs_marker "$repo")" in
            gitlab) provider="gitlab"; edition="selfhosted" ;;
            github) provider="github"; edition="enterprise" ;;
            *)      provider="unknown"; edition="" ;;
          esac
          ;;
      esac
    fi
  fi

  local api_base
  if [ -n "$o_apibase" ]; then
    api_base="$o_apibase"
  else
    api_base="$(_zensu_vcs_api_base "$provider" "$edition" "$host")"
  fi

  local repo_id cli cli_state cli_ready
  repo_id="$(_zensu_vcs_repo_id "$provider" "$path")"
  cli="$(_zensu_vcs_cli_for "$provider")"
  cli_state="$(_zensu_vcs_auth_state "$cli")"
  if [ "$cli_state" = "ready" ]; then cli_ready="true"; else cli_ready="false"; fi

  printf 'provider=%s\n' "$provider"
  printf 'edition=%s\n' "$edition"
  printf 'apiBase=%s\n' "$api_base"
  printf 'repo=%s\n' "$repo_id"
  printf 'cliReady=%s\n' "$cli_ready"
  printf 'cliName=%s\n' "$cli"
  printf 'cliState=%s\n' "$cli_state"
}

_zensu_vcs_is_num() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

_zensu_vcs_is_id() {
  case "${1:-}" in ''|*[!A-Za-z0-9=_-]*) return 1 ;; *) return 0 ;; esac
}

_zensu_vcs_is_gl_repoid() {
  case "${1:-}" in ''|*[!A-Za-z0-9._%-]*) return 1 ;; *) return 0 ;; esac
}

_zensu_vcs_map_state() {
  command -v node >/dev/null 2>&1 || { printf ''; return 0; }
  node -e '
    var s="";process.stdin.on("data",function(c){s+=c;});process.stdin.on("end",function(){
      var st="";try{st=(JSON.parse(s).state||"");}catch(_){}
      st=String(st).toLowerCase();
      var out="";
      if(st==="open"||st==="opened"||st==="locked")out="OPEN";
      else if(st==="merged")out="MERGED";
      else if(st==="closed")out="CLOSED";
      process.stdout.write(out);
    });'
}

_zensu_vcs_normalize_pr() {
  local provider="${1:-}"
  command -v node >/dev/null 2>&1 || { printf ''; return 0; }
  PROV="$provider" node -e '
    var s="";process.stdin.on("data",function(c){s+=c;});process.stdin.on("end",function(){
      var o={id:"",url:"",state:"",base:"",head:""},p=process.env.PROV;
      try{var j=JSON.parse(s);
        if(p==="github"){o.id=String(j.number||"");o.url=j.url||"";o.state=j.state||"";o.base=j.baseRefName||"";o.head=j.headRefName||"";}
        else if(p==="gitlab"){o.id=String(j.iid||"");o.url=j.web_url||"";o.state=j.state||"";o.base=j.target_branch||"";o.head=j.source_branch||"";}
      }catch(_){}
      var st=String(o.state).toLowerCase();
      o.state=st==="merged"?"MERGED":(st==="closed"?"CLOSED":(st?"OPEN":""));
      process.stdout.write(JSON.stringify(o));
    });'
}

_zensu_vcs_normalize_threads() {
  local provider="${1:-}"
  command -v node >/dev/null 2>&1 || { printf '[]'; return 0; }
  PROV="$provider" node -e '
    var s="";process.stdin.on("data",function(c){s+=c;});process.stdin.on("end",function(){
      var out=[],p=process.env.PROV;
      try{var j=JSON.parse(s);
        if(p==="github"){
          var rt=(((j.data||{}).repository||{}).pullRequest||{}).reviewThreads||{};
          var arr=rt.nodes||[];
          for(var i=0;i<arr.length;i++){var t=arr[i];
            if(t&&t.isResolved===false){
              var c=((t.comments||{}).nodes||[])[0]||{};
              out.push({threadId:t.id||"",replyTo:(c.databaseId!=null?String(c.databaseId):""),path:c.path||"",line:(c.line!=null?c.line:null),body:c.body||"",author:((c.author||{}).login)||""});
            }}
        } else if(p==="gitlab"){
          var arr2=Array.isArray(j)?j:(j.discussions||[]);
          for(var k=0;k<arr2.length;k++){var d=arr2[k];
            if(d&&d.resolvable===true&&d.resolved===false){
              var n=((d.notes||[]))[0]||{},pos=n.position||{};
              out.push({threadId:String(d.id||""),replyTo:String(d.id||""),path:pos.new_path||pos.old_path||"",line:(pos.new_line!=null?pos.new_line:null),body:n.body||"",author:((n.author||{}).username)||""});
            }}
        }
      }catch(_){}
      process.stdout.write(JSON.stringify(out));
    });'
}

_zensu_vcs_dry() {
  [ "${ZENSU_VCS_TEST:-}" = "1" ] && [ "${ZENSU_VCS_PRINT_ARGV:-}" = "1" ]
}

_zensu_vcs_pr_state() {
  local provider="" id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --provider) provider="${2:-}"; shift ;;
      --*) ;;
      *) [ -z "$id" ] && id="$1" ;;
    esac
    shift
  done
  [ -n "$provider" ] || return 1
  local argv
  case "$provider" in
    github) argv=(gh pr view --json state -- "$id") ;;
    gitlab) argv=(glab mr view --output json -- "$id") ;;
    *) return 1 ;;
  esac
  if _zensu_vcs_dry; then printf '%s' "${argv[*]}"; return 0; fi
  "${argv[@]}" 2>/dev/null | _zensu_vcs_map_state "$provider"
}

_zensu_vcs_locate_pr() {
  local provider="" num=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --provider) provider="${2:-}"; shift ;;
      --*) ;;
      *) [ -z "$num" ] && num="$1" ;;
    esac
    shift
  done
  [ -n "$provider" ] || return 1
  local argv
  case "$provider" in
    github)
      if [ -n "$num" ]; then argv=(gh pr view --json number,url,state,headRefName,baseRefName -- "$num")
      else argv=(gh pr view --json number,url,state,headRefName,baseRefName); fi ;;
    gitlab)
      if [ -n "$num" ]; then argv=(glab mr view --output json -- "$num")
      else argv=(glab mr view --output json); fi ;;
    *) return 1 ;;
  esac
  if _zensu_vcs_dry; then printf '%s' "${argv[*]}"; return 0; fi
  "${argv[@]}" 2>/dev/null | _zensu_vcs_normalize_pr "$provider"
}

_zensu_vcs_fetch_threads() {
  local provider="" repoid="" id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --provider) provider="${2:-}"; shift ;;
      --repo-id)  repoid="${2:-}"; shift ;;
      --*) ;;
      *) [ -z "$id" ] && id="$1" ;;
    esac
    shift
  done
  [ -n "$provider" ] || return 1
  _zensu_vcs_is_num "$id" || return 1
  local argv
  case "$provider" in
    github)
      case "$repoid" in */?*) : ;; *) return 1 ;; esac
      local owner="${repoid%%/*}" name="${repoid#*/}"
      local q='query($owner:String!,$name:String!,$num:Int!){repository(owner:$owner,name:$name){pullRequest(number:$num){reviewThreads(first:100){nodes{id isResolved comments(first:1){nodes{databaseId body path line author{login}}}}}}}}'
      argv=(gh api graphql -f query="$q" -f owner="$owner" -f name="$name" -F num="$id") ;;
    gitlab)
      argv=(glab api --paginate "projects/$repoid/merge_requests/$id/discussions") ;;
    *) return 1 ;;
  esac
  if _zensu_vcs_dry; then printf '%s' "${argv[*]}"; return 0; fi
  local out rc
  out="$("${argv[@]}" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$out" | _zensu_vcs_normalize_threads "$provider"
}

_zensu_vcs_resolve_thread() {
  local provider="" repoid="" reply="" id="" thread_id="" reply_to=""
  local pos=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --provider) provider="${2:-}"; shift ;;
      --repo-id)  repoid="${2:-}"; shift ;;
      --reply)    reply="${2:-}"; shift ;;
      --*) ;;
      *)
        case "$pos" in
          0) id="$1" ;;
          1) thread_id="$1" ;;
          2) reply_to="$1" ;;
        esac
        pos=$((pos + 1)) ;;
    esac
    shift
  done
  [ -n "$provider" ] || return 1
  [ -n "$reply_to" ] || reply_to="$thread_id"
  _zensu_vcs_is_num "$id" || return 1
  _zensu_vcs_is_id "$thread_id" || return 1
  _zensu_vcs_is_id "$reply_to" || return 1
  local reply_argv=() resolve_argv=()
  case "$provider" in
    github)
      case "$repoid" in */?*) : ;; *) return 1 ;; esac
      local owner="${repoid%%/*}" name="${repoid#*/}"
      [ -n "$reply" ] && reply_argv=(gh api "repos/$owner/$name/pulls/$id/comments/$reply_to/replies" -f body="$reply")
      local m='mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{id}}}'
      resolve_argv=(gh api graphql -f query="$m" -f t="$thread_id") ;;
    gitlab)
      [ -n "$reply" ] && reply_argv=(glab api --method POST "projects/$repoid/merge_requests/$id/discussions/$thread_id/notes" -f body="$reply")
      resolve_argv=(glab api --method PUT "projects/$repoid/merge_requests/$id/discussions/$thread_id?resolved=true") ;;
    *) return 1 ;;
  esac
  if _zensu_vcs_dry; then
    [ "${#reply_argv[@]}" -gt 0 ] && printf '%s\n' "${reply_argv[*]}"
    printf '%s\n' "${resolve_argv[*]}"
    return 0
  fi
  [ "${#reply_argv[@]}" -gt 0 ] && { "${reply_argv[@]}" >/dev/null 2>&1 || return 1; }
  "${resolve_argv[@]}" >/dev/null 2>&1
}

_zensu_vcs_json_field() {
  local field="${1:-}"
  command -v node >/dev/null 2>&1 || { printf ''; return 0; }
  FIELD="$field" node -e '
    var s="";process.stdin.on("data",function(c){s+=c;});process.stdin.on("end",function(){
      var v="";try{v=JSON.parse(s)[process.env.FIELD];}catch(_){}
      process.stdout.write(v==null?"":String(v));
    });'
}

_zensu_vcs_normalize_scout() {
  local provider="${1:-}"
  command -v node >/dev/null 2>&1 || { printf ''; return 0; }
  PROV="$provider" node -e '
    var s="";process.stdin.on("data",function(c){s+=c;});process.stdin.on("end",function(){
      var o={id:"",url:"",state:"",title:"",body:"",base:"",head:"",author:"",labels:[]},p=process.env.PROV;
      try{var j=JSON.parse(s);
        if(p==="github"){
          o.id=String(j.number||"");o.url=j.url||"";o.state=j.state||"";o.title=j.title||"";o.body=j.body||"";
          o.base=j.baseRefName||"";o.head=j.headRefName||"";o.author=((j.author||{}).login)||"";
          o.labels=(j.labels||[]).map(function(l){return (l&&l.name)||"";}).filter(Boolean);
        } else if(p==="gitlab"){
          o.id=String(j.iid||"");o.url=j.web_url||"";o.state=j.state||"";o.title=j.title||"";o.body=j.description||"";
          o.base=j.target_branch||"";o.head=j.source_branch||"";o.author=((j.author||{}).username)||"";
          o.labels=(j.labels||[]).map(function(l){return typeof l==="string"?l:((l&&l.name)||"");}).filter(Boolean);
        }
      }catch(_){}
      var st=String(o.state).toLowerCase();
      o.state=(st==="merged")?"MERGED":((st==="closed")?"CLOSED":(st?"OPEN":""));
      process.stdout.write(JSON.stringify(o));
    });'
}

_zensu_vcs_normalize_diff_refs() {
  local provider="${1:-}"
  command -v node >/dev/null 2>&1 || { printf ''; return 0; }
  PROV="$provider" node -e '
    var s="";process.stdin.on("data",function(c){s+=c;});process.stdin.on("end",function(){
      var o={base_sha:"",start_sha:"",head_sha:""},p=process.env.PROV;
      try{var j=JSON.parse(s);
        if(p==="github"){o.head_sha=j.headRefOid||"";}
        else if(p==="gitlab"){var d=j.diff_refs||{};o.base_sha=d.base_sha||"";o.start_sha=d.start_sha||"";o.head_sha=d.head_sha||"";}
      }catch(_){}
      process.stdout.write(JSON.stringify(o));
    });'
}

_zensu_vcs_scout_pr() {
  local provider="" num=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --provider) provider="${2:-}"; shift ;;
      --repo-id)  shift ;;
      --*) ;;
      *) [ -z "$num" ] && num="$1" ;;
    esac
    shift
  done
  [ -n "$provider" ] || return 1
  [ -z "$num" ] || _zensu_vcs_is_num "$num" || return 1
  local argv
  case "$provider" in
    github)
      if [ -n "$num" ]; then argv=(gh pr view --json number,url,state,title,body,headRefName,baseRefName,author,labels -- "$num")
      else argv=(gh pr view --json number,url,state,title,body,headRefName,baseRefName,author,labels); fi ;;
    gitlab)
      if [ -n "$num" ]; then argv=(glab mr view --output json -- "$num")
      else argv=(glab mr view --output json); fi ;;
    *) return 1 ;;
  esac
  if _zensu_vcs_dry; then printf '%s' "${argv[*]}"; return 0; fi
  "${argv[@]}" 2>/dev/null | _zensu_vcs_normalize_scout "$provider"
}

_zensu_vcs_fetch_pr_ref() {
  local provider="" id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --provider) provider="${2:-}"; shift ;;
      --repo-id)  shift ;;
      --*) ;;
      *) [ -z "$id" ] && id="$1" ;;
    esac
    shift
  done
  [ -n "$provider" ] || return 1
  _zensu_vcs_is_num "$id" || return 1
  case "$provider" in
    github) printf 'pull/%s/head' "$id" ;;
    gitlab) printf 'merge-requests/%s/head' "$id" ;;
    *) return 1 ;;
  esac
}

_zensu_vcs_diff_refs() {
  local provider="" repoid="" id=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --provider) provider="${2:-}"; shift ;;
      --repo-id)  repoid="${2:-}"; shift ;;
      --*) ;;
      *) [ -z "$id" ] && id="$1" ;;
    esac
    shift
  done
  [ -n "$provider" ] || return 1
  [ -z "$id" ] || _zensu_vcs_is_num "$id" || return 1
  local argv
  case "$provider" in
    github)
      if [ -n "$id" ]; then argv=(gh pr view --json headRefOid -- "$id")
      else argv=(gh pr view --json headRefOid); fi ;;
    gitlab)
      _zensu_vcs_is_num "$id" || return 1
      _zensu_vcs_is_gl_repoid "$repoid" || return 1
      argv=(glab api "projects/$repoid/merge_requests/$id") ;;
    *) return 1 ;;
  esac
  if _zensu_vcs_dry; then printf '%s' "${argv[*]}"; return 0; fi
  "${argv[@]}" 2>/dev/null | _zensu_vcs_normalize_diff_refs "$provider"
}

_zensu_vcs_post_review() {
  local provider="" repoid="" diffrefs="" id="" payload=""
  local pos=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --provider)       provider="${2:-}"; shift ;;
      --repo-id)        repoid="${2:-}"; shift ;;
      --diff-refs-json) diffrefs="${2:-}"; shift ;;
      --*) ;;
      *)
        case "$pos" in
          0) id="$1" ;;
          1) payload="$1" ;;
        esac
        pos=$((pos + 1)) ;;
    esac
    shift
  done
  [ -n "$provider" ] || return 1
  _zensu_vcs_is_num "$id" || return 1
  [ -n "$repoid" ] || return 1
  [ -n "$payload" ] || return 1
  case "$provider" in
    github)
      case "$repoid" in */?*) : ;; *) return 1 ;; esac
      local owner="${repoid%%/*}" name="${repoid#*/}"
      local argv=(gh api -X POST "repos/$owner/$name/pulls/$id/reviews" --input "$payload")
      if _zensu_vcs_dry; then printf '%s' "${argv[*]}"; return 0; fi
      [ -f "$payload" ] || return 1
      local resp
      resp="$("${argv[@]}" 2>/dev/null)" || return 1
      printf '%s' "$resp" | _zensu_vcs_json_field html_url ;;
    gitlab)
      _zensu_vcs_post_review_gitlab "$repoid" "$id" "$payload" "$diffrefs" ;;
    *) return 1 ;;
  esac
}

_zensu_vcs_post_review_gitlab() {
  local repoid="$1" id="$2" payload="$3" diffrefs="$4"
  command -v node >/dev/null 2>&1 || return 1
  _zensu_vcs_is_gl_repoid "$repoid" || return 1
  if ! _zensu_vcs_dry; then [ -f "$payload" ] || return 1; fi
  if [ -z "$diffrefs" ]; then
    if _zensu_vcs_dry; then
      diffrefs='{"base_sha":"BASE_SHA","start_sha":"START_SHA","head_sha":"HEAD_SHA"}'
    else
      diffrefs="$(glab api "projects/$repoid/merge_requests/$id" 2>/dev/null | _zensu_vcs_normalize_diff_refs gitlab)"
    fi
  fi
  local ZPLAN='
    var fs=require("fs"),crypto=require("crypto");
    var mode=process.env.ZENSU_PL_MODE||"count";
    var idx=parseInt(process.env.ZENSU_PL_IDX||"0",10);
    var iid=process.env.ZENSU_PL_IID||"",repo=process.env.ZENSU_PL_REPO||"";
    var dr={};try{dr=JSON.parse(process.env.ZENSU_PL_DIFFREFS||"{}");}catch(_){}
    var pl={};try{pl=JSON.parse(fs.readFileSync(process.env.ZENSU_PL_PAYLOAD,"utf8"));}catch(_){}
    function h(x){return crypto.createHash("sha256").update(String(x)).digest("hex").slice(0,8);}
    function mk(tag){return "<!-- zensu:pr"+iid+":"+tag+" -->";}
    function san(v){v=String(v);var o="";for(var z=0;z<v.length;z++){var cc=v.charCodeAt(z);if(cc>31||cc===9||cc===10||cc===13)o+=v[z];}return o;}
    var body=pl.body||"",event=pl.event||"COMMENT";
    var comments=Array.isArray(pl.comments)?pl.comments:[];
    var calls=[];
    var sTag=h(body);
    calls.push({path:"projects/"+repo+"/merge_requests/"+iid+"/notes",
      fields:[["body",mk(sTag)+"\n\n_Verdict: "+event+"_\n\n"+body]],marker:mk(sTag)});
    for(var i=0;i<comments.length;i++){
      var c=comments[i]||{},side=String(c.side||"RIGHT").toUpperCase();
      var hasLine=(c.line!=null&&String(c.line)!=="");
      var line=hasLine?c.line:"";
      var cTag=h((c.path||"")+"\n"+line+"\n"+(c.body||""));
      var f;
      if(hasLine){
        f=[["body",mk(cTag)+"\n\n"+(c.body||"")],
           ["position[position_type]","text"],
           ["position[base_sha]",dr.base_sha||""],
           ["position[start_sha]",dr.start_sha||""],
           ["position[head_sha]",dr.head_sha||""]];
        if(side==="LEFT"){f.push(["position[old_path]",c.path||""]);f.push(["position[old_line]",String(line)]);}
        else{f.push(["position[new_path]",c.path||""]);f.push(["position[new_line]",String(line)]);}
      } else {
        f=[["body",mk(cTag)+"\n\n`"+(c.path||"")+"`: "+(c.body||"")]];
      }
      calls.push({path:"projects/"+repo+"/merge_requests/"+iid+"/discussions",fields:f,marker:mk(cTag),pos:hasLine});
    }
    if(mode==="count"){process.stdout.write(String(calls.length));return;}
    if(mode==="needpos"){var np=0;for(var q=0;q<calls.length;q++){if(calls[q].pos)np=1;}process.stdout.write(String(np));return;}
    var call=calls[idx];if(!call){process.exit(1);}
    var NUL=String.fromCharCode(0);
    var toks=[call.marker,"glab","api","--method","POST",call.path];
    for(var k=0;k<call.fields.length;k++){toks.push("-f");toks.push(call.fields[k][0]+"="+san(call.fields[k][1]));}
    process.stdout.write(toks.join(NUL)+NUL);
  '
  local n
  n="$(ZENSU_PL_MODE=count ZENSU_PL_PAYLOAD="$payload" ZENSU_PL_DIFFREFS="$diffrefs" ZENSU_PL_IID="$id" ZENSU_PL_REPO="$repoid" node -e "$ZPLAN" 2>/dev/null)"
  _zensu_vcs_is_num "$n" || return 1
  if ! _zensu_vcs_dry; then
    local needpos
    needpos="$(ZENSU_PL_MODE=needpos ZENSU_PL_PAYLOAD="$payload" ZENSU_PL_DIFFREFS="$diffrefs" ZENSU_PL_IID="$id" ZENSU_PL_REPO="$repoid" node -e "$ZPLAN" 2>/dev/null)"
    if [ "$needpos" = "1" ]; then
      local drb drh
      drb="$(printf '%s' "$diffrefs" | _zensu_vcs_json_field base_sha)"
      drh="$(printf '%s' "$diffrefs" | _zensu_vcs_json_field head_sha)"
      { [ -n "$drb" ] && [ -n "$drh" ]; } || return 1
    fi
  fi
  local existing=""
  if ! _zensu_vcs_dry; then
    local en ed
    en="$(glab api --paginate "projects/$repoid/merge_requests/$id/notes" 2>/dev/null)" || return 1
    ed="$(glab api --paginate "projects/$repoid/merge_requests/$id/discussions" 2>/dev/null)" || return 1
    existing="$en$ed"
  fi
  local i=0
  while [ "$i" -lt "$n" ]; do
    local all=() t
    while IFS= read -r -d '' t; do all[${#all[@]}]="$t"; done < <(ZENSU_PL_MODE=emit ZENSU_PL_IDX="$i" ZENSU_PL_PAYLOAD="$payload" ZENSU_PL_DIFFREFS="$diffrefs" ZENSU_PL_IID="$id" ZENSU_PL_REPO="$repoid" node -e "$ZPLAN" 2>/dev/null)
    [ "${#all[@]}" -ge 6 ] || return 1
    local mkr="${all[0]}"
    local argv=("${all[@]:1}")
    [ -n "$mkr" ] || return 1
    if _zensu_vcs_dry; then
      printf '%s\n' "${argv[*]}"
    else
      case "$existing" in
        *"$mkr"*) : ;;
        *) "${argv[@]}" >/dev/null 2>&1 || return 1 ;;
      esac
    fi
    i=$((i + 1))
  done
  return 0
}

_zensu_vcs_extract_url() {
  command -v node >/dev/null 2>&1 || { grep -oE 'https?://[^[:space:]]+/(pull|merge_requests)/[0-9]+[^[:space:]]*' | head -n1 | tr -d '[:cntrl:]'; return 0; }
  node -e 'var s="";process.stdin.on("data",function(d){s+=d;});process.stdin.on("end",function(){var m=s.match(/https?:\/\/[^\s]*\/(?:pull|merge_requests)\/[0-9]+[^\s]*/);if(!m){m=s.match(/https?:\/\/[^\s]+/);}var u=m?m[0]:"",o="";for(var z=0;z<u.length;z++){var cc=u.charCodeAt(z);if(cc>=32&&cc!==127){o+=u[z];}}process.stdout.write(o);});'
}

_zensu_vcs_open_pr() {
  local provider="" base="" head="" title="" bodyfile=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --provider)  provider="${2:-}"; shift ;;
      --base)      base="${2:-}"; shift ;;
      --head)      head="${2:-}"; shift ;;
      --title)     title="${2:-}"; shift ;;
      --body-file) bodyfile="${2:-}"; shift ;;
      --*) ;;
      *) ;;
    esac
    shift
  done
  [ -n "$provider" ] || return 1
  [ -n "$base" ] || return 1
  [ -n "$head" ] || return 1
  [ -n "$title" ] || return 1
  [ -n "$bodyfile" ] || return 1
  local argv
  case "$provider" in
    github)
      argv=(gh pr create --title "$title" --body-file "$bodyfile" --base "$base" --head "$head")
      if _zensu_vcs_dry; then printf '%s' "${argv[*]}"; return 0; fi
      [ -f "$bodyfile" ] || return 1 ;;
    gitlab)
      if ! _zensu_vcs_dry; then [ -f "$bodyfile" ] || return 1; fi
      local body=""
      [ -f "$bodyfile" ] && body="$(cat "$bodyfile")"
      argv=(glab mr create --title "$title" --description "$body" --source-branch "$head" --target-branch "$base" --yes)
      if _zensu_vcs_dry; then printf '%s' "${argv[*]}"; return 0; fi ;;
    *) return 1 ;;
  esac
  local out rc
  out="$("${argv[@]}" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] || { printf '%s' "$out" >&2; return "$rc"; }
  printf '%s' "$out" | _zensu_vcs_extract_url
}

export -f _zensu_vcs_remote_url _zensu_vcs_split_url _zensu_vcs_classify_host _zensu_vcs_probeable_host _zensu_vcs_probe _zensu_vcs_marker _zensu_vcs_api_base _zensu_vcs_repo_id _zensu_vcs_cli_for _zensu_vcs_auth_state _zensu_vcs_detect _zensu_vcs_is_num _zensu_vcs_is_id _zensu_vcs_is_gl_repoid _zensu_vcs_map_state _zensu_vcs_normalize_pr _zensu_vcs_normalize_threads _zensu_vcs_dry _zensu_vcs_pr_state _zensu_vcs_locate_pr _zensu_vcs_fetch_threads _zensu_vcs_resolve_thread _zensu_vcs_json_field _zensu_vcs_normalize_scout _zensu_vcs_normalize_diff_refs _zensu_vcs_scout_pr _zensu_vcs_fetch_pr_ref _zensu_vcs_diff_refs _zensu_vcs_post_review _zensu_vcs_post_review_gitlab _zensu_vcs_extract_url _zensu_vcs_open_pr 2>/dev/null || true

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    --detect)         _zensu_vcs_detect "$@" ;;
    --pr-state)       shift; _zensu_vcs_pr_state "$@" ;;
    --locate-pr)      shift; _zensu_vcs_locate_pr "$@" ;;
    --fetch-threads)  shift; _zensu_vcs_fetch_threads "$@" ;;
    --resolve-thread) shift; _zensu_vcs_resolve_thread "$@" ;;
    --scout-pr)       shift; _zensu_vcs_scout_pr "$@" ;;
    --fetch-pr-ref)   shift; _zensu_vcs_fetch_pr_ref "$@" ;;
    --diff-refs)      shift; _zensu_vcs_diff_refs "$@" ;;
    --post-review)    shift; _zensu_vcs_post_review "$@" ;;
    --open-pr)        shift; _zensu_vcs_open_pr "$@" ;;
    *) printf 'usage: zensu-vcs.sh --detect|--pr-state|--locate-pr|--fetch-threads|--resolve-thread|--scout-pr|--fetch-pr-ref|--diff-refs|--post-review|--open-pr [--provider github|gitlab] [--repo-id R] [--reply TEXT] [--diff-refs-json JSON] [--base B] [--head H] [--title T] [--body-file F] [args]\n' >&2; exit 2 ;;
  esac
fi
