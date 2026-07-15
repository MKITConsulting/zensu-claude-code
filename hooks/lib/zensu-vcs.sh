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

_zensu_vcs_is_gh_repoid() {
  local repoid="${1:-}" owner name
  case "$repoid" in */*) ;; *) return 1 ;; esac
  owner="${repoid%%/*}"; name="${repoid#*/}"
  case "$name" in */*) return 1 ;; esac
  case "$owner" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$name" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

_zensu_vcs_is_gl_repoid() {
  local repoid="${1:-}" rest tail pair lower
  case "$repoid" in ''|.|..|*..*|*[!A-Za-z0-9._%-]*) return 1 ;; esac
  rest="$repoid"
  while [ "$rest" != "${rest#*%}" ]; do
    tail="${rest#*%}"; pair="${tail:0:2}"
    [ "${#pair}" -eq 2 ] || return 1
    case "$pair" in *[!0-9A-Fa-f]*) return 1 ;; esac
    lower="$(printf '%s' "$pair" | tr '[:upper:]' '[:lower:]')"
    [ "$lower" != "2e" ] || return 1
    rest="${tail:2}"
  done
  return 0
}

_zensu_vcs_map_state() {
  command -v node >/dev/null 2>&1 || return 1
  node -e '
    var s="";process.stdin.on("data",function(c){s+=c;});process.stdin.on("end",function(){
      var st="";try{var j=JSON.parse(s);if(!j||typeof j.state!=="string")throw new Error();st=j.state;}catch(_){process.exit(1);return;}
      st=String(st).toLowerCase();
      var out="";
      if(st==="open"||st==="opened"||st==="locked")out="OPEN";
      else if(st==="merged")out="MERGED";
      else if(st==="closed")out="CLOSED";
      else{process.exit(1);return;}process.stdout.write(out);
    });'
}

_zensu_vcs_normalize_pr() {
  local provider="${1:-}"
  command -v node >/dev/null 2>&1 || return 1
  PROV="$provider" node -e '
    var s="";process.stdin.on("data",function(c){s+=c;});process.stdin.on("end",function(){
      var o={id:"",url:"",state:"",base:"",head:""},p=process.env.PROV;
      function id(v){if((Number.isSafeInteger(v)&&v>0)||(typeof v==="string"&&/^[1-9][0-9]*$/.test(v)&&Number.isSafeInteger(Number(v))))return String(v);throw new Error();}
      function text(v){if(typeof v!=="string"||!v||v.length>1024||/[\u0000-\u001f\u007f]/.test(v))throw new Error();return v;}
      function url(v){if(typeof v!=="string"||/[\s\u0000-\u001f\u007f]/.test(v))throw new Error();var u=new URL(v);if(!["http:","https:"].includes(u.protocol)||!u.hostname||u.username||u.password)throw new Error();return v;}
      try{var j=JSON.parse(s);if(!j||typeof j!=="object"||Array.isArray(j))throw new Error();
        if(p==="github"){o.id=id(j.number);o.url=url(j.url);o.state=text(j.state);o.base=text(j.baseRefName);o.head=text(j.headRefName);}
        else if(p==="gitlab"){o.id=id(j.iid);o.url=url(j.web_url);o.state=text(j.state);o.base=text(j.target_branch);o.head=text(j.source_branch);}
        else throw new Error();
      }catch(_){process.exit(1);return;}
      var st=String(o.state).toLowerCase();
      if(st==="merged")o.state="MERGED";else if(st==="closed")o.state="CLOSED";else if(st==="open"||st==="opened"||st==="locked")o.state="OPEN";else{process.exit(1);return;}
      process.stdout.write(JSON.stringify(o));
    });'
}

_zensu_vcs_normalize_threads() {
  local provider="${1:-}"
  command -v node >/dev/null 2>&1 || return 1
  PROV="$provider" node -e '
    var s="";process.stdin.on("data",function(c){s+=c;});process.stdin.on("end",function(){
      var out=[],p=process.env.PROV;
      try{var j=JSON.parse(s);
        if(p==="github"){
          var pages=Array.isArray(j)?j:[j],seen={};if(!pages.length)throw new Error("empty github pagination");
          for(var pg=0;pg<pages.length;pg++){
            if(pages[pg]&&Object.prototype.hasOwnProperty.call(pages[pg],"errors")
                && (!Array.isArray(pages[pg].errors)||pages[pg].errors.length>0))throw new Error("github graphql errors");
            var pr=pages[pg]&&pages[pg].data&&pages[pg].data.repository&&pages[pg].data.repository.pullRequest;
            var rt=pr&&pr.reviewThreads;
            if(!rt||!Array.isArray(rt.nodes)||!rt.pageInfo||typeof rt.pageInfo.hasNextPage!=="boolean"){throw new Error("invalid github thread page");}
            if(pg<pages.length-1){if(rt.pageInfo.hasNextPage!==true||typeof rt.pageInfo.endCursor!=="string"||!rt.pageInfo.endCursor)throw new Error("broken github pagination");}
            else if(rt.pageInfo.hasNextPage!==false)throw new Error("truncated github pagination");
            for(var i=0;i<rt.nodes.length;i++){var t=rt.nodes[i];
              if(!t||typeof t.id!=="string"||!t.id||typeof t.isResolved!=="boolean")throw new Error("invalid github thread");
              var cn=(t.comments&&t.comments.nodes)||[];
              if(!Array.isArray(cn)){throw new Error("invalid github thread comments");}
              var c=cn[0];
              if(!c||typeof c!=="object"||Array.isArray(c)||!Number.isSafeInteger(c.databaseId)
                  ||c.databaseId<1||typeof c.body!=="string"||typeof c.path!=="string"
                  ||!(c.line==null||(Number.isSafeInteger(c.line)&&c.line>0)))throw new Error("invalid github root comment");
              if(c.author!=null&&(!c.author||typeof c.author!=="object"||Array.isArray(c.author)
                  ||(c.author.login!=null&&typeof c.author.login!=="string")))throw new Error("invalid github comment author");
              var normalized={threadId:t.id,replyTo:String(c.databaseId),path:c.path,line:(c.line!=null?c.line:null),body:c.body,author:(c.author&&c.author.login)||""};
              var signature=JSON.stringify({resolved:t.isResolved,thread:normalized});
              if(Object.prototype.hasOwnProperty.call(seen,t.id)){
                if(seen[t.id]!==signature)throw new Error("conflicting duplicate github thread");
                continue;
              }
              seen[t.id]=signature;
              if(t.isResolved===false)out.push(normalized);
            }
          }
        } else if(p==="gitlab"){
          var raw=Array.isArray(j)?j:(j&&j.discussions);
          if(!Array.isArray(raw)){throw new Error("invalid gitlab discussions");}
          var arr2=[];for(var a=0;a<raw.length;a++){if(Array.isArray(raw[a]))arr2=arr2.concat(raw[a]);else arr2.push(raw[a]);}
          var seenNotes={},seenThreads={};
          for(var k=0;k<arr2.length;k++){var d=arr2[k];
            if(!d||typeof d!=="object"||Array.isArray(d)||typeof d.id!=="string"||!d.id
                ||/[\u0000-\u001f\u007f]/.test(d.id)||!Array.isArray(d.notes)||!d.notes.length
                ||(d.resolvable!=null&&typeof d.resolvable!=="boolean")
                ||(d.resolved!=null&&typeof d.resolved!=="boolean")){throw new Error("invalid gitlab discussion");}
            for(var q=0;q<d.notes.length;q++){var candidate=d.notes[q];
              if(!candidate||typeof candidate!=="object"||Array.isArray(candidate)
                  ||!((Number.isSafeInteger(candidate.id)&&candidate.id>0)||(typeof candidate.id==="string"&&/^[1-9][0-9]*$/.test(candidate.id)&&Number.isSafeInteger(Number(candidate.id))))
                  ||typeof candidate.body!=="string"
                  ||(candidate.resolvable!=null&&typeof candidate.resolvable!=="boolean")
                  ||(candidate.resolved!=null&&typeof candidate.resolved!=="boolean"))throw new Error("invalid gitlab note");
              var candidatePos=candidate.position;
              if(candidatePos!=null&&(!candidatePos||typeof candidatePos!=="object"||Array.isArray(candidatePos)
                  ||(candidatePos.new_path!=null&&typeof candidatePos.new_path!=="string")
                  ||(candidatePos.old_path!=null&&typeof candidatePos.old_path!=="string")
                  ||!(candidatePos.new_line==null||(Number.isSafeInteger(candidatePos.new_line)&&candidatePos.new_line>0))
                  ||!(candidatePos.old_line==null||(Number.isSafeInteger(candidatePos.old_line)&&candidatePos.old_line>0))))throw new Error("invalid gitlab note position");
              if(candidate.author!=null&&(!candidate.author||typeof candidate.author!=="object"||Array.isArray(candidate.author)
                  ||(candidate.author.username!=null&&typeof candidate.author.username!=="string")))throw new Error("invalid gitlab note author");
            }
            var discussionSignature=JSON.stringify({resolvable:d.resolvable,resolved:d.resolved,notes:d.notes.map(function(note){
              var pos=(note&&note.position)||{},author=(note&&note.author)||{};
              return {id:note&&note.id,resolvable:note&&note.resolvable,resolved:note&&note.resolved,
                body:note&&note.body,author:author.username,new_path:pos.new_path,old_path:pos.old_path,
                new_line:pos.new_line,old_line:pos.old_line};
            })});
            if(Object.prototype.hasOwnProperty.call(seenThreads,d.id)){
              if(seenThreads[d.id]!==discussionSignature)throw new Error("conflicting duplicate gitlab discussion");
              continue;
            }
            seenThreads[d.id]=discussionSignature;
            var chosen=null;
            for(var z=0;z<d.notes.length;z++){var n=d.notes[z],nid=String(n.id);
              var npos=n.position||{},nauthor=n.author||{};
              var noteSignature=JSON.stringify({body:n.body,resolvable:n.resolvable,resolved:n.resolved,
                author:nauthor.username,new_path:npos.new_path,old_path:npos.old_path,
                new_line:npos.new_line,old_line:npos.old_line});
              if(Object.prototype.hasOwnProperty.call(seenNotes,nid)){
                throw new Error("duplicate gitlab note across discussions");
              }
              seenNotes[nid]=noteSignature;
              var resolvable=n.resolvable!=null?n.resolvable:d.resolvable;
              var resolved=n.resolved!=null?n.resolved:d.resolved;
              if(typeof resolvable!=="boolean"||typeof resolved!=="boolean")throw new Error("incomplete gitlab resolution state");
              if(chosen===null&&resolvable===true&&resolved===false)chosen=n;
            }
            if(chosen){var pos=chosen.position||{};
              out.push({threadId:String(d.id),replyTo:String(d.id),path:pos.new_path||pos.old_path||"",line:(pos.new_line!=null?pos.new_line:(pos.old_line!=null?pos.old_line:null)),body:chosen.body||"",author:((chosen.author||{}).username)||""});
            }
          }
        } else {throw new Error("unknown provider");}
      }catch(_){process.exitCode=1;return;}
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
  local out
  out="$("${argv[@]}" 2>/dev/null)" || return 1
  printf '%s' "$out" | _zensu_vcs_map_state "$provider"
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
  local out
  out="$("${argv[@]}" 2>/dev/null)" || return 1
  printf '%s' "$out" | _zensu_vcs_normalize_pr "$provider"
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
      _zensu_vcs_is_gh_repoid "$repoid" || return 1
      local owner="${repoid%%/*}" name="${repoid#*/}"
      local q='query($owner:String!,$name:String!,$num:Int!,$endCursor:String){repository(owner:$owner,name:$name){pullRequest(number:$num){reviewThreads(first:100,after:$endCursor){nodes{id isResolved comments(first:1){nodes{databaseId body path line author{login}}}}pageInfo{hasNextPage endCursor}}}}}'
      argv=(gh api graphql --paginate --slurp -f query="$q" -f owner="$owner" -f name="$name" -F num="$id") ;;
    gitlab)
      _zensu_vcs_is_gl_repoid "$repoid" || return 1
      argv=(glab api --paginate --output json "projects/$repoid/merge_requests/$id/discussions") ;;
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
      _zensu_vcs_is_gh_repoid "$repoid" || return 1
      local owner="${repoid%%/*}" name="${repoid#*/}"
      [ -n "$reply" ] && reply_argv=(gh api "repos/$owner/$name/pulls/$id/comments/$reply_to/replies" -f body="$reply")
      local m='mutation($t:ID!){resolveReviewThread(input:{threadId:$t}){thread{id}}}'
      resolve_argv=(gh api graphql -f query="$m" -f t="$thread_id") ;;
    gitlab)
      _zensu_vcs_is_gl_repoid "$repoid" || return 1
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
  command -v node >/dev/null 2>&1 || return 1
  FIELD="$field" node -e '
    var s="";process.stdin.on("data",function(c){s+=c;});process.stdin.on("end",function(){
      var v="";try{var j=JSON.parse(s);if(!j||typeof j!=="object"||Array.isArray(j))throw new Error();v=j[process.env.FIELD];if(v!==null&&typeof v==="object")throw new Error();}catch(_){process.exit(1);return;}
      process.stdout.write(v==null?"":String(v));
    });'
}

_zensu_vcs_json_http_url_field() {
  local field="${1:-}"
  command -v node >/dev/null 2>&1 || return 1
  FIELD="$field" node -e '
    var s="";process.stdin.on("data",function(c){s+=c;});process.stdin.on("end",function(){
      var v;try{var j=JSON.parse(s);if(!j||typeof j!=="object"||Array.isArray(j))throw new Error();v=j[process.env.FIELD];
        if(typeof v!=="string"||/[\s\u0000-\u001f\u007f]/.test(v))throw new Error();var u=new URL(v);
        if(!["http:","https:"].includes(u.protocol)||!u.hostname||u.username||u.password)throw new Error();
      }catch(_){process.exit(1);return;}process.stdout.write(v);
    });'
}

_zensu_vcs_normalize_scout() {
  local provider="${1:-}"
  command -v node >/dev/null 2>&1 || return 1
  PROV="$provider" node -e '
    var s="";process.stdin.on("data",function(c){s+=c;});process.stdin.on("end",function(){
      var o={id:"",url:"",state:"",title:"",body:"",base:"",head:"",author:"",labels:[]},p=process.env.PROV;
      function id(v){if((Number.isSafeInteger(v)&&v>0)||(typeof v==="string"&&/^[1-9][0-9]*$/.test(v)&&Number.isSafeInteger(Number(v))))return String(v);throw new Error();}
      function text(v,empty,max){if(typeof v!=="string"||(!empty&&!v)||v.length>(max||65536)||/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(v))throw new Error();return v;}
      function branch(v){v=text(v,false);if(v.length>1024||/[\u0000-\u001f\u007f]/.test(v))throw new Error();return v;}
      function url(v){if(typeof v!=="string"||/[\s\u0000-\u001f\u007f]/.test(v))throw new Error();var u=new URL(v);if(!["http:","https:"].includes(u.protocol)||!u.hostname||u.username||u.password)throw new Error();return v;}
      function author(v,key){if(v==null)return "";if(!v||typeof v!=="object"||Array.isArray(v))throw new Error();if(v[key]==null)return "";return text(v[key],true);}
      function labels(v,gitlab){if(!Array.isArray(v))throw new Error();return v.map(function(l){
        if(gitlab&&typeof l==="string")return text(l,false);
        if(!l||typeof l!=="object"||Array.isArray(l))throw new Error();return text(l.name,false);
      });}
      try{var j=JSON.parse(s);if(!j||typeof j!=="object"||Array.isArray(j))throw new Error();
        if(p==="github"){
          o.id=id(j.number);o.url=url(j.url);o.state=text(j.state,false);o.title=text(j.title,false);o.body=j.body==null?"":text(j.body,true,65536);
          o.base=branch(j.baseRefName);o.head=branch(j.headRefName);o.author=author(j.author,"login");o.labels=labels(j.labels,false);
        } else if(p==="gitlab"){
          o.id=id(j.iid);o.url=url(j.web_url);o.state=text(j.state,false);o.title=text(j.title,false);o.body=j.description==null?"":text(j.description,true,1048576);
          o.base=branch(j.target_branch);o.head=branch(j.source_branch);o.author=author(j.author,"username");o.labels=labels(j.labels,true);
        }
        else throw new Error();
      }catch(_){process.exit(1);return;}
      var st=String(o.state).toLowerCase();
      if(st==="merged")o.state="MERGED";else if(st==="closed")o.state="CLOSED";else if(st==="open"||st==="opened"||st==="locked")o.state="OPEN";else{process.exit(1);return;}
      process.stdout.write(JSON.stringify(o));
    });'
}

_zensu_vcs_normalize_diff_refs() {
  local provider="${1:-}"
  command -v node >/dev/null 2>&1 || return 1
  PROV="$provider" node -e '
    var s="";process.stdin.on("data",function(c){s+=c;});process.stdin.on("end",function(){
      var o={base_sha:"",start_sha:"",head_sha:""},p=process.env.PROV;
      try{var j=JSON.parse(s);if(!j||typeof j!=="object"||Array.isArray(j))throw new Error();
        var hex=/^[0-9a-fA-F]{7,64}$/;
        if(p==="github"){if(typeof j.headRefOid!=="string"||!hex.test(j.headRefOid))throw new Error();o.head_sha=j.headRefOid.toLowerCase();}
        else if(p==="gitlab"){var d=j.diff_refs;if(!d||typeof d!=="object"||Array.isArray(d)
          ||typeof d.base_sha!=="string"||typeof d.start_sha!=="string"||typeof d.head_sha!=="string"
          ||!hex.test(d.base_sha)||!hex.test(d.start_sha)||!hex.test(d.head_sha))throw new Error();
          o.base_sha=d.base_sha.toLowerCase();o.start_sha=d.start_sha.toLowerCase();o.head_sha=d.head_sha.toLowerCase();}
        else throw new Error();
      }catch(_){process.exit(1);return;}
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
  local out
  out="$("${argv[@]}" 2>/dev/null)" || return 1
  printf '%s' "$out" | _zensu_vcs_normalize_scout "$provider"
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
  local out
  out="$("${argv[@]}" 2>/dev/null)" || return 1
  printf '%s' "$out" | _zensu_vcs_normalize_diff_refs "$provider"
}

_zensu_vcs_snapshot_review_payload() {
  local source_file="${1:-}" snapshot_file="${2:-}"
  command -v node >/dev/null 2>&1 || return 1
  [ -n "$source_file" ] && [ -n "$snapshot_file" ] || return 1
  SOURCE_FILE="$source_file" SNAPSHOT_FILE="$snapshot_file" node -e '
    const fs=require("fs"),max=8*1024*1024;
    const source=process.env.SOURCE_FILE,snapshot=process.env.SNAPSHOT_FILE;
    let before,sourceFd,opened,after,data,target,targetFd,targetOpened;
    try{
      before=fs.lstatSync(source);
      if(!before.isFile()||before.isSymbolicLink()||before.nlink!==1||before.size>max)process.exit(1);
      sourceFd=fs.openSync(source,fs.constants.O_RDONLY|(fs.constants.O_NOFOLLOW||0));
      opened=fs.fstatSync(sourceFd);
      if(!opened.isFile()||opened.nlink!==1||opened.dev!==before.dev||opened.ino!==before.ino||opened.size>max)process.exit(1);
      data=fs.readFileSync(sourceFd);after=fs.fstatSync(sourceFd);fs.closeSync(sourceFd);sourceFd=undefined;
      if(data.length>max||after.size!==opened.size||after.mtimeMs!==opened.mtimeMs||after.ctimeMs!==opened.ctimeMs)process.exit(1);
      target=fs.lstatSync(snapshot);
      if(!target.isFile()||target.isSymbolicLink()||target.nlink!==1)process.exit(1);
      targetFd=fs.openSync(snapshot,fs.constants.O_WRONLY|(fs.constants.O_NOFOLLOW||0));
      targetOpened=fs.fstatSync(targetFd);
      if(!targetOpened.isFile()||targetOpened.nlink!==1||targetOpened.dev!==target.dev||targetOpened.ino!==target.ino)process.exit(1);
      fs.ftruncateSync(targetFd,0);fs.fchmodSync(targetFd,0o600);fs.writeFileSync(targetFd,data);fs.closeSync(targetFd);targetFd=undefined;
    }catch(_){if(sourceFd!==undefined){try{fs.closeSync(sourceFd);}catch(__){}}if(targetFd!==undefined){try{fs.closeSync(targetFd);}catch(__){}}process.exit(1);}
  ' 2>/dev/null
}

_zensu_vcs_review_payload_meta() {
  local provider="${1:-}" payload="${2:-}" head="${3:-}" operation_key="${4:-}"
  command -v node >/dev/null 2>&1 || return 1
  case "$provider" in github|gitlab) ;; *) return 1 ;; esac
  [ -f "$payload" ] || return 1
  [ -n "$operation_key" ] || return 1
  PROVIDER="$provider" PAYLOAD="$payload" HEAD_SHA="$head" OPERATION_KEY="$operation_key" node -e '
    var fs=require("fs"),crypto=require("crypto");
    function fail(){process.exit(1);}
    function digest(s){return crypto.createHash("sha256").update(s).digest("hex");}
    function canonical(v){
      if(v===null||typeof v==="string"||typeof v==="boolean")return JSON.stringify(v);
      if(typeof v==="number")return isFinite(v)?JSON.stringify(v):fail();
      if(Array.isArray(v))return "["+v.map(canonical).join(",")+"]";
      if(typeof v==="object")return "{"+Object.keys(v).sort().map(function(k){return JSON.stringify(k)+":"+canonical(v[k]);}).join(",")+"}";
      fail();
    }
    var head=String(process.env.HEAD_SHA||"").toLowerCase();
    var op=String(process.env.OPERATION_KEY||"");
    var unsafeText=/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/;
    if(!/^[0-9a-f]{7,64}$/.test(head)||!op||op.length>256||/[\u0000-\u001f\u007f]/.test(op))fail();
    var p;try{p=JSON.parse(fs.readFileSync(process.env.PAYLOAD,"utf8"));}catch(_){fail();}
    if(!p||Array.isArray(p)||typeof p!=="object")fail();
    if(!Object.keys(p).every(function(k){return ["body","event","comments","commit_id"].includes(k);}))fail();
    if(typeof p.body!=="string"||unsafeText.test(p.body)||!["COMMENT","APPROVE","REQUEST_CHANGES"].includes(p.event)||p.body.indexOf("zensu-review:v1")>=0)fail();
    if(p.commit_id!=null&&(typeof p.commit_id!=="string"||p.commit_id.toLowerCase()!==head))fail();
    var comments=p.comments==null?[]:p.comments;if(!Array.isArray(comments))fail();
    comments.forEach(function(c){
      if(!c||Array.isArray(c)||typeof c!=="object"||typeof c.body!=="string"||unsafeText.test(c.body)||c.body.indexOf("zensu-review:v1")>=0)fail();
      if(!Object.keys(c).every(function(k){return ["body","path","line","side","start_line","start_side"].includes(k);}))fail();
      if(typeof c.path!=="string"||!c.path||/[\u0000-\u001f\u007f]/.test(c.path)||c.path.indexOf("zensu-review:v1")>=0)fail();
      if(c.side!=null&&c.side!=="LEFT"&&c.side!=="RIGHT")fail();
      if(c.line!=null&&(!Number.isSafeInteger(c.line)||c.line<1))fail();
      var hasStartLine=c.start_line!=null,hasStartSide=c.start_side!=null;
      if(hasStartLine!==hasStartSide)fail();
      if(hasStartLine&&(!Number.isSafeInteger(c.start_line)||c.start_line<1||c.start_line>c.line
          ||(c.start_side!=="LEFT"&&c.start_side!=="RIGHT")||c.start_side!==c.side))fail();
      if(process.env.PROVIDER==="github"&&(!Number.isSafeInteger(c.line)||c.line<1||(c.side!=="LEFT"&&c.side!=="RIGHT")))fail();
      if(process.env.PROVIDER==="gitlab"&&(hasStartLine||hasStartSide))fail();
    });
    var n=process.env.PROVIDER==="github"?1:comments.length+1;if(n>999999)fail();
    var od=digest(op),pd=digest(canonical(p));
    var marker="<!-- zensu-review:v1:"+od+":"+pd+":"+head+":"+n+":part=1/"+n+" -->";
    process.stdout.write(JSON.stringify({opDigest:od,payloadDigest:pd,headSha:head,partCount:n,marker:marker}));
  '
}

_zensu_vcs_review_marker() {
  local op_digest="${1:-}" payload_digest="${2:-}" head="${3:-}" part_count="${4:-}" part="${5:-}"
  [ "${#op_digest}" -eq 64 ] && [ "${#payload_digest}" -eq 64 ] || return 1
  case "$op_digest$payload_digest" in *[!0-9a-f]*) return 1 ;; esac
  [ "${#head}" -ge 7 ] && [ "${#head}" -le 64 ] || return 1
  case "$head" in *[!0-9a-f]*) return 1 ;; esac
  _zensu_vcs_is_num "$part_count" || return 1
  _zensu_vcs_is_num "$part" || return 1
  [ "$part_count" -gt 0 ] && [ "$part_count" -le 999999 ] && [ "$part" -gt 0 ] && [ "$part" -le "$part_count" ] || return 1
  printf '<!-- zensu-review:v1:%s:%s:%s:%s:part=%s/%s -->' "$op_digest" "$payload_digest" "$head" "$part_count" "$part" "$part_count"
}

_zensu_vcs_review_inventory() {
  local provider="${1:-}" op_digest="${2:-}" payload_digest="${3:-}" head="${4:-}" part_count="${5:-}"
  command -v node >/dev/null 2>&1 || return 1
  case "$provider" in github|gitlab) ;; *) return 1 ;; esac
  PROVIDER="$provider" OP_DIGEST="$op_digest" PAYLOAD_DIGEST="$payload_digest" HEAD_SHA="$head" PART_COUNT="$part_count" node -e '
    var s="";process.stdin.on("data",function(c){s+=c;});process.stdin.on("end",function(){
      function fail(){process.exit(1);}
      var op=process.env.OP_DIGEST||"",pd=process.env.PAYLOAD_DIGEST||"",head=String(process.env.HEAD_SHA||"").toLowerCase();
      var n=Number(process.env.PART_COUNT||"");
      if(!/^[0-9a-f]{64}$/.test(op)||!/^[0-9a-f]{64}$/.test(pd)||!/^[0-9a-f]{7,64}$/.test(head)||!Number.isSafeInteger(n)||n<1||n>999999)fail();
      var j;try{j=JSON.parse(s);}catch(_){fail();}
      var records=[],seenIds={},seenDiscussions={},seenDiscussionNotes={};
      function canonical(v){
        if(v===null||typeof v==="string"||typeof v==="boolean")return JSON.stringify(v);
        if(typeof v==="number")return isFinite(v)?JSON.stringify(v):fail();
        if(Array.isArray(v))return "["+v.map(canonical).join(",")+"]";
        if(typeof v==="object")return "{"+Object.keys(v).sort().map(function(k){return JSON.stringify(k)+":"+canonical(v[k]);}).join(",")+"}";
        fail();
      }
      function gitlabNoteMeta(note){
        if(!Object.prototype.hasOwnProperty.call(note,"type")
            ||!(note.type===null||typeof note.type==="string"))fail();
        var position=Object.prototype.hasOwnProperty.call(note,"position")?note.position:null;
        if(position!=null&&(!position||typeof position!=="object"||Array.isArray(position)))fail();
        if(note.type!=="DiffNote"&&position!=null)fail();
        return {type:note.type,position:position,positionKey:canonical(position)};
      }
      function validGitlabInline(record){
        if(record.noteType==="DiscussionNote")return record.position===null;
        if(record.noteType!=="DiffNote"||!record.position)return false;
        var p=record.position,hex=/^[0-9a-f]{7,64}$/;
        function line(v){return v==null||(Number.isSafeInteger(v)&&v>0);}
        return p.position_type==="text"&&typeof p.base_sha==="string"&&hex.test(p.base_sha)
          &&typeof p.start_sha==="string"&&hex.test(p.start_sha)
          &&typeof p.head_sha==="string"&&p.head_sha===head
          &&typeof p.old_path==="string"&&p.old_path.length>0
          &&typeof p.new_path==="string"&&p.new_path.length>0
          &&line(p.old_line)&&line(p.new_line)&&(p.old_line!=null||p.new_line!=null);
      }
      function add(id,body,url,kind,meta){
        if(process.env.PROVIDER==="github"){
          if(typeof id!=="string"||!id)fail();
        }else{
          if(!((Number.isSafeInteger(id)&&id>0)||(typeof id==="string"&&/^[1-9][0-9]*$/.test(id)&&Number.isSafeInteger(Number(id)))))fail();
        }
        id=String(id);if(typeof body!=="string")fail();
        if(url==null||url==="")url="";
        else {try{if(typeof url!=="string"||/[\s\u0000-\u001f\u007f]/.test(url))fail();var parsedUrl=new URL(url);
          if(!["http:","https:"].includes(parsedUrl.protocol)||!parsedUrl.hostname||parsedUrl.username||parsedUrl.password)fail();}catch(_){fail();}}
        if(process.env.PROVIDER==="github"&&!url)fail();
        if(Object.prototype.hasOwnProperty.call(seenIds,id)){
          var prev=seenIds[id];if(prev.body!==body||(prev.url&&url&&prev.url!==url))fail();
          if(process.env.PROVIDER==="gitlab"
              &&(prev.noteType!==meta.type||prev.positionKey!==meta.positionKey))fail();
          if(!prev.url&&url)prev.url=url;prev.kinds[kind]=true;return;
        }
        var record={body:body,url:url,kinds:{}};
        if(process.env.PROVIDER==="gitlab"){
          record.noteType=meta.type;record.position=meta.position;record.positionKey=meta.positionKey;
        }
        record.kinds[kind]=true;seenIds[id]=record;records.push(record);
      }
      if(process.env.PROVIDER==="github"){
        var pages=Array.isArray(j)?j:[j];if(!pages.length)fail();
        for(var p=0;p<pages.length;p++){
          if(pages[p]&&Object.prototype.hasOwnProperty.call(pages[p],"errors")
              && (!Array.isArray(pages[p].errors)||pages[p].errors.length>0))fail();
          var reviews=pages[p]&&pages[p].data&&pages[p].data.repository&&pages[p].data.repository.pullRequest&&pages[p].data.repository.pullRequest.reviews;
          if(!reviews||!Array.isArray(reviews.nodes)||!reviews.pageInfo||typeof reviews.pageInfo.hasNextPage!=="boolean")fail();
          if(p<pages.length-1){if(reviews.pageInfo.hasNextPage!==true||typeof reviews.pageInfo.endCursor!=="string"||!reviews.pageInfo.endCursor)fail();}
          else if(reviews.pageInfo.hasNextPage!==false)fail();
          for(var r=0;r<reviews.nodes.length;r++){var rv=reviews.nodes[r]||{};add(rv.id,rv.body,rv.url,"review");}
        }
      }else{
        if(!j||Array.isArray(j)||typeof j!=="object"||!("notes" in j)||!("discussions" in j))fail();
        function flatten(v){if(!Array.isArray(v))fail();var out=[];for(var i=0;i<v.length;i++){if(Array.isArray(v[i]))out=out.concat(v[i]);else out.push(v[i]);}return out;}
        var notes=flatten(j.notes),discussions=flatten(j.discussions);
        for(var a=0;a<notes.length;a++){var no=notes[a];if(!no||no.id==null)fail();add(no.id,no.body,no.web_url!=null?no.web_url:no.url,"note",gitlabNoteMeta(no));}
        for(var d=0;d<discussions.length;d++){var di=discussions[d];
          if(!di||typeof di.id!=="string"||!di.id||typeof di.individual_note!=="boolean"||!Array.isArray(di.notes)||!di.notes.length)fail();
          if(di.individual_note&&di.notes.length!==1)fail();
          var noteIds=[],localNoteIds={};for(var q=0;q<di.notes.length;q++){var qi=di.notes[q];if(!qi||qi.id==null)fail();
            var qid=String(qi.id);if(localNoteIds[qid])fail();localNoteIds[qid]=true;noteIds.push(qid);
            if(Object.prototype.hasOwnProperty.call(seenDiscussionNotes,qid)&&seenDiscussionNotes[qid]!==di.id)fail();
            seenDiscussionNotes[qid]=di.id;
          }
          var discussionSignature=JSON.stringify({individual:di.individual_note,noteIds:noteIds});
          if(Object.prototype.hasOwnProperty.call(seenDiscussions,di.id)&&seenDiscussions[di.id]!==discussionSignature)fail();
          seenDiscussions[di.id]=discussionSignature;
          for(var z=0;z<di.notes.length;z++){var dn=di.notes[z];add(dn.id,dn.body,dn.web_url!=null?dn.web_url:dn.url,z===0?(di.individual_note?"individual":"discussion"):"reply",gitlabNoteMeta(dn));}
        }
      }
      var exact={},url="";
      var re=/<!-- zensu-review:v1:([0-9a-f]{64}):([0-9a-f]{64}):([0-9a-f]{7,64}):([1-9][0-9]*):part=([1-9][0-9]*)\/([1-9][0-9]*) -->/g;
      for(var x=0;x<records.length;x++){
        var body=records[x].body,mentions=(body.match(/<!-- zensu-review:v1:/g)||[]).length,matches=[],m;re.lastIndex=0;while((m=re.exec(body))!==null)matches.push(m);
        if(process.env.PROVIDER==="gitlab"&&((records[x].kinds.individual
            &&(records[x].kinds.discussion||records[x].kinds.reply))
            ||(records[x].kinds.discussion&&records[x].kinds.reply)))fail();
        if(mentions!==matches.length||matches.length>1)fail();
        for(var y=0;y<matches.length;y++){m=matches[y];if(m[1]!==op)continue;
          var mn=Number(m[4]),part=Number(m[5]),denom=Number(m[6]);
          if(m[2]!==pd||m[3]!==head||mn!==n||denom!==n||part<1||part>n)fail();
          if(process.env.PROVIDER==="github"&&!records[x].kinds.review)fail();
          if(process.env.PROVIDER==="gitlab"&&((part===1&&(!records[x].kinds.note||!records[x].kinds.individual
                  ||records[x].kinds.discussion||records[x].kinds.reply||records[x].noteType!==null||records[x].position!==null))
              ||(part>1&&(!records[x].kinds.discussion||records[x].kinds.individual||records[x].kinds.reply
                  ||!validGitlabInline(records[x])))))fail();
          if(exact[part])fail();exact[part]=1;if(!url)url=records[x].url;
        }
      }
      var present=Object.keys(exact).map(Number).sort(function(a,b){return a-b;});
      process.stdout.write(JSON.stringify({present:present,url:url}));
    });'
}

_zensu_vcs_review_snapshot() {
  local provider="${1:-}" repoid="${2:-}" id="${3:-}"
  local out
  case "$provider" in
    github) out="$(gh api "repos/$repoid/pulls/$id" 2>/dev/null)" || return 1 ;;
    gitlab) out="$(glab api "projects/$repoid/merge_requests/$id" 2>/dev/null)" || return 1 ;;
    *) return 1 ;;
  esac
  PROVIDER="$provider" node -e '
    var s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{
      function fail(){process.exit(1);}var j;try{j=JSON.parse(s);}catch(_){fail();}
      var state="",head="",url="";
      if(process.env.PROVIDER==="github"){
        if(!j||typeof j.state!=="string"||!j.head||typeof j.head.sha!=="string")fail();state=j.state;head=j.head.sha;url=j.html_url;
      }else{
        if(!j||typeof j!=="object"||typeof j.state!=="string")fail();state=j.state;head=j.sha||((j.diff_refs||{}).head_sha);url=j.web_url;
        if(typeof head!=="string")fail();
      }
      state=String(state||"").toLowerCase();head=String(head||"").toLowerCase();
      var parsedUrl;try{parsedUrl=new URL(url);}catch(_){fail();}
      if((state!=="open"&&state!=="opened"&&state!=="locked")||!/^[0-9a-f]{7,64}$/.test(head)||typeof url!=="string"
        ||/[\s\u0000-\u001f\u007f]/.test(url)||!["http:","https:"].includes(parsedUrl.protocol)
        ||!parsedUrl.hostname||parsedUrl.username||parsedUrl.password)fail();
      process.stdout.write(JSON.stringify({state:"OPEN",headSha:head,url:url}));
    });' <<<"$out"
}

_zensu_vcs_review_fetch_inventory() {
  local provider="${1:-}" repoid="${2:-}" id="${3:-}"
  case "$provider" in
    github)
      local owner="${repoid%%/*}" name="${repoid#*/}"
      local q='query($owner:String!,$name:String!,$num:Int!,$endCursor:String){repository(owner:$owner,name:$name){pullRequest(number:$num){reviews(first:100,after:$endCursor){nodes{id body url}pageInfo{hasNextPage endCursor}}}}}'
      gh api graphql --paginate --slurp -f query="$q" -f owner="$owner" -f name="$name" -F num="$id" 2>/dev/null ;;
    gitlab)
      local notes discussions notes_file discussions_file combined
      notes="$(glab api --paginate --output json "projects/$repoid/merge_requests/$id/notes" 2>/dev/null)" || return 1
      discussions="$(glab api --paginate --output json "projects/$repoid/merge_requests/$id/discussions" 2>/dev/null)" || return 1
      notes_file="$(mktemp "${TMPDIR:-/tmp}/zensu-review-notes.XXXXXXXX")" || return 1
      discussions_file="$(mktemp "${TMPDIR:-/tmp}/zensu-review-discussions.XXXXXXXX")" || { rm -f "$notes_file"; return 1; }
      printf '%s' "$notes" > "$notes_file" || { rm -f "$notes_file" "$discussions_file"; return 1; }
      printf '%s' "$discussions" > "$discussions_file" || { rm -f "$notes_file" "$discussions_file"; return 1; }
      combined="$(NOTES_FILE="$notes_file" DISCUSSIONS_FILE="$discussions_file" node -e '
        var fs=require("fs"),n,d;try{n=JSON.parse(fs.readFileSync(process.env.NOTES_FILE,"utf8"));d=JSON.parse(fs.readFileSync(process.env.DISCUSSIONS_FILE,"utf8"));}catch(_){process.exit(1);}
        process.stdout.write(JSON.stringify({notes:n,discussions:d}));')" || { rm -f "$notes_file" "$discussions_file"; return 1; }
      rm -f "$notes_file" "$discussions_file"
      printf '%s' "$combined" ;;
    *) return 1 ;;
  esac
}

_zensu_vcs_review_assert_head() {
  local snapshot="${1:-}" expected="${2:-}"
  local actual
  actual="$(printf '%s' "$snapshot" | _zensu_vcs_json_field headSha)"
  [ -n "$actual" ] && [ "$actual" = "$expected" ]
}

_zensu_vcs_review_present_parts() {
  command -v node >/dev/null 2>&1 || return 1
  node -e '
    var s="";process.stdin.on("data",c=>s+=c);process.stdin.on("end",()=>{
      var j;try{j=JSON.parse(s);}catch(_){process.exit(1);}
      if(!j||!Array.isArray(j.present)||!j.present.every(Number.isSafeInteger))process.exit(1);
      process.stdout.write(JSON.stringify(j.present));
    });'
}

_zensu_vcs_review_full_parts() {
  local part_count="${1:-}"
  _zensu_vcs_is_num "$part_count" || return 1
  PART_COUNT="$part_count" node -e '
    var n=Number(process.env.PART_COUNT);if(!Number.isSafeInteger(n)||n<1)process.exit(1);
    var a=[];for(var i=1;i<=n;i++)a.push(i);process.stdout.write(JSON.stringify(a));'
}

_zensu_vcs_review_has_part() {
  local present="${1:-}" part="${2:-}"
  PRESENT="$present" PART="$part" node -e '
    var a,p;try{a=JSON.parse(process.env.PRESENT);p=Number(process.env.PART);}catch(_){process.exit(1);}
    if(!Array.isArray(a)||!Number.isSafeInteger(p))process.exit(1);process.exit(a.indexOf(p)>=0?0:1);'
}

_zensu_vcs_review_validate_diffrefs() {
  local diffrefs="${1:-}" head="${2:-}" require_full="${3:-0}"
  DIFFREFS="$diffrefs" HEAD_SHA="$head" REQUIRE_FULL="$require_full" node -e '
    var d;try{d=JSON.parse(process.env.DIFFREFS);}catch(_){process.exit(1);}
    var hex=/^[0-9a-f]{7,64}$/;
    if(!d||typeof d!=="object"||Array.isArray(d)||typeof d.head_sha!=="string"
      ||!hex.test(d.head_sha)||d.head_sha!==process.env.HEAD_SHA)process.exit(1);
    if(process.env.REQUIRE_FULL==="1"&&(typeof d.base_sha!=="string"||typeof d.start_sha!=="string"
      ||!hex.test(d.base_sha)||!hex.test(d.start_sha)))process.exit(1);'
}

_zensu_vcs_review_gitlab_diff_plan() {
  local payload="${1:-}" diffrefs="${2:-}" head="${3:-}"
  command -v node >/dev/null 2>&1 || return 1
  [ -f "$payload" ] || return 1
  PAYLOAD="$payload" DIFFREFS="$diffrefs" HEAD_SHA="$head" node -e '
    var fs=require("fs"),raw="";
    process.stdin.on("data",function(c){raw+=c;});process.stdin.on("end",function(){
      function fail(){process.exit(1);}
      var payload,pages,dr;try{payload=JSON.parse(fs.readFileSync(process.env.PAYLOAD,"utf8"));pages=JSON.parse(raw);dr=JSON.parse(process.env.DIFFREFS);}catch(_){fail();}
      if(!payload||typeof payload!=="object"||Array.isArray(payload)||!Array.isArray(payload.comments))fail();
      var hex=/^[0-9a-f]{7,64}$/;
      if(!dr||typeof dr!=="object"||Array.isArray(dr)||!hex.test(dr.head_sha)||dr.head_sha!==process.env.HEAD_SHA)fail();
      var base=dr.base_sha==null?null:dr.base_sha,start=dr.start_sha==null?null:dr.start_sha;
      if((base!==null&&!hex.test(base))||(start!==null&&!hex.test(start)))fail();
      if(payload.comments.length>0&&(base===null||start===null))fail();
      var diffs=[];
      function flatten(v){if(!Array.isArray(v))fail();v.forEach(function(x){if(Array.isArray(x))flatten(x);else diffs.push(x);});}
      flatten(pages);
      var candidates=new Map(),unsafe=/[\u0000-\u001f\u007f]/;
      function key(side,path,line){return JSON.stringify([side,path,line]);}
      function merge(entries){entries.forEach(function(e){var k=key(e.side,e.path,e.line),a=candidates.get(k)||[];a.push(e.anchor);candidates.set(k,a);});}
      function parseDiff(d){
        var lines=d.diff.split("\n"),entries=[],inHunk=false,fatal=false;
        var oldLine=0,newLine=0,oldCount=0,newCount=0,oldUsed=0,newUsed=0;
        function finish(){if(inHunk&&(oldUsed!==oldCount||newUsed!==newCount))fatal=true;}
        function number(s){var n=Number(s);return Number.isSafeInteger(n)&&n>=0?n:null;}
        function add(side,path,line,anchor){if(Number.isSafeInteger(line)&&line>0)entries.push({side:side,path:path,line:line,anchor:anchor});}
        for(var i=0;i<lines.length&&!fatal;i++){
          var line=lines[i],m;
          if(line.slice(0,2)==="@@"){
            finish();if(fatal)break;
            m=line.match(/^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?:.*)$/);
            if(!m){fatal=true;break;}
            oldLine=number(m[1]);newLine=number(m[3]);oldCount=m[2]==null?1:number(m[2]);newCount=m[4]==null?1:number(m[4]);
            if(oldLine==null||newLine==null||oldCount==null||newCount==null
                ||(oldLine===0&&oldCount!==0)||(newLine===0&&newCount!==0)
                ||(oldCount>0&&oldLine>Number.MAX_SAFE_INTEGER-oldCount+1)
                ||(newCount>0&&newLine>Number.MAX_SAFE_INTEGER-newCount+1)){fatal=true;break;}
            oldUsed=0;newUsed=0;inHunk=true;continue;
          }
          if(!inHunk){if(line===""&&i===lines.length-1)continue;return null;}
          if(line===""&&i===lines.length-1)continue;
          if(line==="\\ No newline at end of file")continue;
          var anchor;
          if(line.charAt(0)===" "){
            anchor={old_path:d.old_path,new_path:d.new_path,old_line:oldLine,new_line:newLine};
            add("LEFT",d.old_path,oldLine,anchor);add("RIGHT",d.new_path,newLine,anchor);
            oldLine++;newLine++;oldUsed++;newUsed++;
          }else if(line.charAt(0)==="-"){
            anchor={old_path:d.old_path,new_path:d.new_path,old_line:oldLine,new_line:null};
            add("LEFT",d.old_path,oldLine,anchor);oldLine++;oldUsed++;
          }else if(line.charAt(0)==="+"){
            anchor={old_path:d.old_path,new_path:d.new_path,old_line:null,new_line:newLine};
            add("RIGHT",d.new_path,newLine,anchor);newLine++;newUsed++;
          }else fatal=true;
          if(oldUsed>oldCount||newUsed>newCount)fatal=true;
        }
        finish();return fatal?false:entries;
      }
      diffs.forEach(function(d){
        if(!d||typeof d!=="object"||Array.isArray(d)||typeof d.old_path!=="string"||!d.old_path
            ||typeof d.new_path!=="string"||!d.new_path||unsafe.test(d.old_path)||unsafe.test(d.new_path))fail();
        ["collapsed","too_large"].forEach(function(k){if(Object.prototype.hasOwnProperty.call(d,k)&&typeof d[k]!=="boolean")fail();});
        if(d.collapsed===true||d.too_large===true)return;
        if(typeof d.diff!=="string")fail();
        var entries=parseDiff(d);if(entries===false)fail();if(entries!==null)merge(entries);
      });
      var plan=payload.comments.map(function(c){
        if(!c||c.line==null)return {kind:"general"};
        var found=candidates.get(key(String(c.side||"RIGHT").toUpperCase(),c.path,c.line))||[];
        if(found.length!==1)return {kind:"general"};
        var a=found[0];return {kind:"position",old_path:a.old_path,new_path:a.new_path,old_line:a.old_line,new_line:a.new_line};
      });
      process.stdout.write(JSON.stringify({base_sha:base,start_sha:start,head_sha:dr.head_sha,comments:plan}));
    });'
}

_zensu_vcs_review_gitlab_call() {
  local repoid="${1:-}" id="${2:-}" payload="${3:-}" diffrefs="${4:-}" op_digest="${5:-}" payload_digest="${6:-}" head="${7:-}" part_count="${8:-}" part="${9:-}" plan="${10:-}"
  PROVIDER=gitlab PAYLOAD="$payload" PLAN="$plan" DIFFREFS="$diffrefs" OP_DIGEST="$op_digest" PAYLOAD_DIGEST="$payload_digest" HEAD_SHA="$head" PART_COUNT="$part_count" PART="$part" REPO_ID="$repoid" REVIEW_ID="$id" node -e '
    var fs=require("fs"),p,pl,dr;function fail(){process.exit(1);}
    try{p=JSON.parse(fs.readFileSync(process.env.PAYLOAD,"utf8"));pl=JSON.parse(fs.readFileSync(process.env.PLAN,"utf8"));dr=JSON.parse(process.env.DIFFREFS);}catch(_){fail();}
    var part=Number(process.env.PART),n=Number(process.env.PART_COUNT),comments=p.comments||[];
    if(!Number.isSafeInteger(part)||part<1||part>n||!dr||dr.head_sha!==process.env.HEAD_SHA
        ||!pl||typeof pl!=="object"||Array.isArray(pl)||JSON.stringify(Object.keys(pl).sort())!==JSON.stringify(["base_sha","comments","head_sha","start_sha"])
        ||pl.base_sha!==(dr.base_sha==null?null:dr.base_sha)||pl.start_sha!==(dr.start_sha==null?null:dr.start_sha)||pl.head_sha!==dr.head_sha
        ||!Array.isArray(pl.comments)||pl.comments.length!==comments.length)fail();
    function line(v){return v===null||(Number.isSafeInteger(v)&&v>0);}
    pl.comments.forEach(function(a){
      if(!a||typeof a!=="object"||Array.isArray(a))fail();
      var keys=Object.keys(a).sort();
      if(a.kind==="general"){if(JSON.stringify(keys)!==JSON.stringify(["kind"]))fail();return;}
      if(a.kind!=="position"||JSON.stringify(keys)!==JSON.stringify(["kind","new_line","new_path","old_line","old_path"]))fail();
      if(typeof a.old_path!=="string"||!a.old_path||typeof a.new_path!=="string"||!a.new_path
          ||!line(a.old_line)||!line(a.new_line)||(a.old_line===null&&a.new_line===null))fail();
    });
    function san(v){v=String(v);var o="";for(var z=0;z<v.length;z++){var c=v.charCodeAt(z);if(c>31||c===9||c===10||c===13)o+=v[z];}return o;}
    var marker="<!-- zensu-review:v1:"+process.env.OP_DIGEST+":"+process.env.PAYLOAD_DIGEST+":"+process.env.HEAD_SHA+":"+n+":part="+part+"/"+n+" -->";
    var path="projects/"+process.env.REPO_ID+"/merge_requests/"+process.env.REVIEW_ID,fields=[];
    if(part===1){path+="/notes";fields.push(["body",marker+"\n\n_Verdict: "+p.event+"_\n\n"+p.body]);}
    else{
      var c=comments[part-2],anchor=pl.comments[part-2];if(!c||!anchor)fail();path+="/discussions";
      if(anchor.kind==="position"){
        fields.push(["body",marker+"\n\n"+c.body],["position[position_type]","text"],["position[base_sha]",dr.base_sha||""],["position[start_sha]",dr.start_sha||""],["position[head_sha]",dr.head_sha||""],["position[old_path]",anchor.old_path],["position[new_path]",anchor.new_path]);
        if(anchor.old_line!==null)fields.push(["position[old_line]",String(anchor.old_line)]);
        if(anchor.new_line!==null)fields.push(["position[new_line]",String(anchor.new_line)]);
      }else fields.push(["body",marker+"\n\n`"+(c.path||"")+"`: "+c.body]);
    }
    var zero=String.fromCharCode(0),tokens=["glab","api","--method","POST",path];
    fields.forEach(function(f){tokens.push("-f");tokens.push(f[0]+"="+san(f[1]));});process.stdout.write(tokens.join(zero)+zero);'
}

_zensu_vcs_review_result() {
  STATUS="${1:-}" MARKER="${2:-}" HEAD_SHA="${3:-}" PART_COUNT="${4:-}" POSTED_COUNT="${5:-}" URL_VALUE="${6:-}" node -e '
    var n=Number(process.env.PART_COUNT),p=Number(process.env.POSTED_COUNT);
    var s=process.env.STATUS;
    if(!["present","posted","reconciled"].includes(s)||!Number.isSafeInteger(n)||n<1||n>999999||!Number.isSafeInteger(p)||p<0||p>n)process.exit(1);
    if((s==="present"&&p!==0)||(s==="posted"&&p!==n)||(s==="reconciled"&&(p<1||p>=n)))process.exit(1);
    var marker=(process.env.MARKER||"").match(/^<!-- zensu-review:v1:([0-9a-f]{64}):([0-9a-f]{64}):([0-9a-f]{7,64}):([1-9][0-9]*):part=1\/([1-9][0-9]*) -->$/);
    if(!marker||marker[3]!==process.env.HEAD_SHA||Number(marker[4])!==n||Number(marker[5])!==n)process.exit(1);
    try{var u=new URL(process.env.URL_VALUE||"");if(/[\s\u0000-\u001f\u007f]/.test(process.env.URL_VALUE)
      ||!["http:","https:"].includes(u.protocol)||!u.hostname||u.username||u.password)process.exit(1);}catch(_){process.exit(1);}
    process.stdout.write(JSON.stringify({status:process.env.STATUS,marker:process.env.MARKER,headSha:process.env.HEAD_SHA,partCount:n,postedCount:p,url:process.env.URL_VALUE||""}));'
}

_zensu_vcs_reconcile_review() (
  local provider="" repoid="" diffrefs="" expected_head="" operation_key="" id="" payload=""
  local pos=0 seen_provider=0 seen_repoid=0 seen_diffrefs=0 seen_head=0 seen_operation=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --provider) [ "$seen_provider" -eq 0 ] && [ $# -ge 2 ] || return 1; provider="$2"; seen_provider=1; shift ;;
      --repo-id) [ "$seen_repoid" -eq 0 ] && [ $# -ge 2 ] || return 1; repoid="$2"; seen_repoid=1; shift ;;
      --diff-refs-json) [ "$seen_diffrefs" -eq 0 ] && [ $# -ge 2 ] || return 1; diffrefs="$2"; seen_diffrefs=1; shift ;;
      --expected-head) [ "$seen_head" -eq 0 ] && [ $# -ge 2 ] || return 1; expected_head="$2"; seen_head=1; shift ;;
      --operation-key) [ "$seen_operation" -eq 0 ] && [ $# -ge 2 ] || return 1; operation_key="$2"; seen_operation=1; shift ;;
      --*) return 1 ;;
      *)
        case "$pos" in
          0) id="$1" ;;
          1) payload="$1" ;;
          2) [ "$seen_operation" -eq 0 ] || return 1; operation_key="$1"; seen_operation=1 ;;
          *) return 1 ;;
        esac
        pos=$((pos + 1)) ;;
    esac
    shift
  done
  case "$provider" in github|gitlab) ;; *) return 1 ;; esac
  _zensu_vcs_is_num "$id" || return 1
  [ -n "$repoid" ] && [ -n "$payload" ] && [ -n "$operation_key" ] || return 1
  case "$provider" in github) _zensu_vcs_is_gh_repoid "$repoid" || return 1 ;; gitlab) _zensu_vcs_is_gl_repoid "$repoid" || return 1 ;; esac
  expected_head="$(printf '%s' "$expected_head" | tr '[:upper:]' '[:lower:]')"
  local payload_snapshot gitlab_diffs_file="" gitlab_plan_file=""
  payload_snapshot="$(mktemp "${TMPDIR:-/tmp}/zensu-review-payload.XXXXXXXX")" || return 1
  trap 'rm -f -- "$payload_snapshot"; [ -z "$gitlab_diffs_file" ] || rm -f -- "$gitlab_diffs_file"; [ -z "$gitlab_plan_file" ] || rm -f -- "$gitlab_plan_file"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  _zensu_vcs_snapshot_review_payload "$payload" "$payload_snapshot" || return 1
  payload="$payload_snapshot"
  local meta op_digest payload_digest head part_count marker
  meta="$(_zensu_vcs_review_payload_meta "$provider" "$payload" "$expected_head" "$operation_key")" || return 1
  op_digest="$(printf '%s' "$meta" | _zensu_vcs_json_field opDigest)"
  payload_digest="$(printf '%s' "$meta" | _zensu_vcs_json_field payloadDigest)"
  head="$(printf '%s' "$meta" | _zensu_vcs_json_field headSha)"
  part_count="$(printf '%s' "$meta" | _zensu_vcs_json_field partCount)"
  marker="$(printf '%s' "$meta" | _zensu_vcs_json_field marker)"
  local before raw inventory present full url status posted_count=0
  before="$(_zensu_vcs_review_snapshot "$provider" "$repoid" "$id")" || return 1
  _zensu_vcs_review_assert_head "$before" "$head" || return 1
  url="$(printf '%s' "$before" | _zensu_vcs_json_field url)"
  raw="$(_zensu_vcs_review_fetch_inventory "$provider" "$repoid" "$id")" || return 1
  inventory="$(printf '%s' "$raw" | _zensu_vcs_review_inventory "$provider" "$op_digest" "$payload_digest" "$head" "$part_count")" || return 1
  present="$(printf '%s' "$inventory" | _zensu_vcs_review_present_parts)" || return 1
  full="$(_zensu_vcs_review_full_parts "$part_count")" || return 1

  if [ "$present" = "$full" ]; then
    status="present"
    if [ "$provider" = github ]; then
      local existing_url; existing_url="$(printf '%s' "$inventory" | _zensu_vcs_json_field url)"; [ -z "$existing_url" ] || url="$existing_url"
    fi
  elif [ "$present" = "[]" ] && [ "$provider" = "github" ]; then
    local post_input post_response post_url
    before="$(_zensu_vcs_review_snapshot "$provider" "$repoid" "$id")" || return 1
    _zensu_vcs_review_assert_head "$before" "$head" || return 1
    post_input="$(mktemp "${TMPDIR:-/tmp}/zensu-review.XXXXXXXX")" || return 1
    if ! PAYLOAD="$payload" MARKER="$marker" HEAD_SHA="$head" node -e '
      var fs=require("fs"),j;try{j=JSON.parse(fs.readFileSync(process.env.PAYLOAD,"utf8"));}catch(_){process.exit(1);}
      j.body=process.env.MARKER+"\n\n"+j.body;j.commit_id=process.env.HEAD_SHA;process.stdout.write(JSON.stringify(j));' > "$post_input"; then rm -f "$post_input"; return 1; fi
    post_response="$(gh api -X POST "repos/$repoid/pulls/$id/reviews" --input "$post_input" 2>/dev/null)" || { rm -f "$post_input"; return 1; }
    rm -f "$post_input"
    post_url="$(printf '%s' "$post_response" | _zensu_vcs_json_http_url_field html_url)" || return 1
    url="$post_url"; status="posted"; posted_count=1
  elif [ "$provider" = "gitlab" ]; then
    if [ -z "$diffrefs" ]; then
      local diff_response diff_attempt=1
      while [ "$diff_attempt" -le 5 ]; do
        before="$(_zensu_vcs_review_snapshot "$provider" "$repoid" "$id")" || return 1
        _zensu_vcs_review_assert_head "$before" "$head" || return 1
        diff_response="$(glab api "projects/$repoid/merge_requests/$id" 2>/dev/null)" || return 1
        if diffrefs="$(printf '%s' "$diff_response" | _zensu_vcs_normalize_diff_refs gitlab 2>/dev/null)"; then
          break
        fi
        diffrefs=""
        [ "$diff_attempt" -lt 5 ] || return 1
        sleep 1
        diff_attempt=$((diff_attempt + 1))
      done
    fi
    local require_full=0; [ "$part_count" -gt 1 ] && require_full=1
    _zensu_vcs_review_validate_diffrefs "$diffrefs" "$head" "$require_full" || return 1
    gitlab_diffs_file="$(mktemp "${TMPDIR:-/tmp}/zensu-review-diffs.XXXXXXXX")" || return 1
    gitlab_plan_file="$(mktemp "${TMPDIR:-/tmp}/zensu-review-plan.XXXXXXXX")" || return 1
    if [ "$part_count" -gt 1 ]; then
      glab api --paginate --output json "projects/$repoid/merge_requests/$id/diffs" > "$gitlab_diffs_file" 2>/dev/null || return 1
    else
      printf '[]' > "$gitlab_diffs_file" || return 1
    fi
    _zensu_vcs_review_gitlab_diff_plan "$payload" "$diffrefs" "$head" < "$gitlab_diffs_file" > "$gitlab_plan_file" || return 1
    rm -f -- "$gitlab_diffs_file"; gitlab_diffs_file=""
    if [ "$present" = "[]" ]; then status="posted"; else status="reconciled"; fi
    local i=1
    while [ "$i" -le "$part_count" ]; do
      if ! _zensu_vcs_review_has_part "$present" "$i"; then
        before="$(_zensu_vcs_review_snapshot "$provider" "$repoid" "$id")" || return 1
        _zensu_vcs_review_assert_head "$before" "$head" || return 1
        local argv=() token
        while IFS= read -r -d '' token; do argv[${#argv[@]}]="$token"; done < <(_zensu_vcs_review_gitlab_call "$repoid" "$id" "$payload" "$diffrefs" "$op_digest" "$payload_digest" "$head" "$part_count" "$i" "$gitlab_plan_file")
        [ "${#argv[@]}" -ge 7 ] || return 1
        "${argv[@]}" >/dev/null 2>&1 || return 1
        posted_count=$((posted_count + 1))
      fi
      i=$((i + 1))
    done
  else return 1
  fi

  if [ "$posted_count" -gt 0 ]; then
    raw="$(_zensu_vcs_review_fetch_inventory "$provider" "$repoid" "$id")" || return 1
    inventory="$(printf '%s' "$raw" | _zensu_vcs_review_inventory "$provider" "$op_digest" "$payload_digest" "$head" "$part_count")" || return 1
    present="$(printf '%s' "$inventory" | _zensu_vcs_review_present_parts)" || return 1
    [ "$present" = "$full" ] || return 1
  fi
  local after
  after="$(_zensu_vcs_review_snapshot "$provider" "$repoid" "$id")" || return 1
  _zensu_vcs_review_assert_head "$after" "$head" || return 1
  _zensu_vcs_review_result "$status" "$marker" "$head" "$part_count" "$posted_count" "$url"
)

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
      _zensu_vcs_is_gh_repoid "$repoid" || return 1
      local owner="${repoid%%/*}" name="${repoid#*/}"
      local argv=(gh api -X POST "repos/$owner/$name/pulls/$id/reviews" --input "$payload")
      if _zensu_vcs_dry; then printf '%s' "${argv[*]}"; return 0; fi
      [ -f "$payload" ] || return 1
      local resp
      resp="$("${argv[@]}" 2>/dev/null)" || return 1
      printf '%s' "$resp" | _zensu_vcs_json_http_url_field html_url ;;
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
      local diff_response
      diff_response="$(glab api "projects/$repoid/merge_requests/$id" 2>/dev/null)" || return 1
      diffrefs="$(printf '%s' "$diff_response" | _zensu_vcs_normalize_diff_refs gitlab)" || return 1
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

export -f _zensu_vcs_remote_url _zensu_vcs_split_url _zensu_vcs_classify_host _zensu_vcs_probeable_host _zensu_vcs_probe _zensu_vcs_marker _zensu_vcs_api_base _zensu_vcs_repo_id _zensu_vcs_cli_for _zensu_vcs_auth_state _zensu_vcs_detect _zensu_vcs_is_num _zensu_vcs_is_id _zensu_vcs_is_gh_repoid _zensu_vcs_is_gl_repoid _zensu_vcs_map_state _zensu_vcs_normalize_pr _zensu_vcs_normalize_threads _zensu_vcs_dry _zensu_vcs_pr_state _zensu_vcs_locate_pr _zensu_vcs_fetch_threads _zensu_vcs_resolve_thread _zensu_vcs_json_field _zensu_vcs_json_http_url_field _zensu_vcs_normalize_scout _zensu_vcs_normalize_diff_refs _zensu_vcs_scout_pr _zensu_vcs_fetch_pr_ref _zensu_vcs_diff_refs _zensu_vcs_snapshot_review_payload _zensu_vcs_review_payload_meta _zensu_vcs_review_marker _zensu_vcs_review_inventory _zensu_vcs_review_snapshot _zensu_vcs_review_fetch_inventory _zensu_vcs_review_assert_head _zensu_vcs_review_present_parts _zensu_vcs_review_full_parts _zensu_vcs_review_has_part _zensu_vcs_review_validate_diffrefs _zensu_vcs_review_gitlab_diff_plan _zensu_vcs_review_gitlab_call _zensu_vcs_review_result _zensu_vcs_reconcile_review _zensu_vcs_post_review _zensu_vcs_post_review_gitlab _zensu_vcs_extract_url _zensu_vcs_open_pr 2>/dev/null || true

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
    --reconcile-review) shift; _zensu_vcs_reconcile_review "$@" ;;
    --post-review)    shift; _zensu_vcs_post_review "$@" ;;
    --open-pr)        shift; _zensu_vcs_open_pr "$@" ;;
    *) printf 'usage: zensu-vcs.sh --detect|--pr-state|--locate-pr|--fetch-threads|--resolve-thread|--scout-pr|--fetch-pr-ref|--diff-refs|--reconcile-review|--post-review|--open-pr [--provider github|gitlab] [--repo-id R] [--reply TEXT] [--diff-refs-json JSON] [--expected-head SHA] [--operation-key KEY] [--base B] [--head H] [--title T] [--body-file F] [args]\n' >&2; exit 2 ;;
  esac
fi
