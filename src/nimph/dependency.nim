import std/uri
import std/strformat
import std/strutils
import std/sets
import std/hashes
import std/strtabs
import std/tables
import std/options

import bump

import nimph/spec
import nimph/package
import nimph/project
import nimph/version
import nimph/git

import nimph/group
export group

type
  Dependency* = ref object
    names*: seq[string]
    requirement*: Requirement
    packages*: PackageGroup
    projects*: ProjectGroup

  DependencyGroup* = ref object of Group[Requirement, Dependency]

proc name*(dependency: Dependency): string =
  result = dependency.names.join("|")

proc `$`*(dependency: Dependency): string =
  result = dependency.name & "->" & $dependency.requirement

proc newDependency*(requirement: Requirement): Dependency =
  result = Dependency(requirement: requirement)
  result.projects = newProjectGroup()
  result.packages = newPackageGroup()

proc newDependencyGroup*(flags: set[Flag]): DependencyGroup =
  result = DependencyGroup(flags: flags)
  result.init(flags, mode = modeStyleInsensitive)

proc contains*(dependencies: DependencyGroup; package: Package): bool =
  for name, dependency in dependencies.pairs:
    result = package.url in dependency.packages
    if result:
      break

proc hasKey*(dependencies: DependencyGroup; name: string): bool =
  result = dependencies.imports.hasKey(name)

proc reportMultipleResolutions(project: Project; requirement: Requirement;
                               packages: PackageGroup) =
  ## output some useful warnings depending upon the nature of the dupes
  var
    urls: HashSet[Hash]
  for url in packages.urls:
    urls.incl url.hash

  if urls.len == 1:
    warn &"{project.name} has {packages.len} " &
         &"options for {requirement} dependency, all via"
    for url in packages.urls:
      warn &"\t{url}"
      break
  else:
    warn &"{project.name} has {packages.len} " &
         &"options for {requirement} dependency:"
  var count = 1
  for name, package in packages.pairs:
    if package.local:
      warn &"\t{count}\t{package.path}"
    elif package.web.isValid:
      warn &"\t{count}\t{package.web}"
    if urls.len != 1:
      warn &"\t{package.url}\n"
    count.inc
  fatal ""

proc asPackage*(project: Project): Package =
  ## cast a project to a package
  result = newPackage(name = project.name, path = project.repo,
                      dist = project.dist, url = project.createUrl())

proc adopt*(parent: Project; child: var Project) =
  ## associate a child project with the parent project of which the
  ## child is a requirement, member of local dependencies, or otherwise
  ## available to the compiler's search paths
  if child.parent != nil and child.parent != parent:
    let emsg = &"{parent} cannot adopt {child}"
    raise newException(Defect, emsg)
  child.parent = parent

proc childProjects*(project: var Project): ProjectGroup =
  ## compose a group of possible dependencies of the project
  result = project.availableProjects
  for child in result.mvalues:
    if child == project:
      continue
    project.adopt(child)
    discard child.fetchConfig

proc determineDeps*(project: Project): Option[Requires] =
  ## try to parse requirements of a project
  if project.dump == nil:
    error "unable to determine deps without issuing a dump"
    return
  result = parseRequires(project.dump["requires"])

proc determineDeps*(project: var Project): Option[Requires] =
  ## try to parse requirements of a (mutable) project
  if not project.fetchDump():
    debug "nimble dump failed, so computing deps is impossible"
    return
  let
    immutable = project
  result = determineDeps(immutable)

proc peelRelease*(project: Project; release: Release): Release =
  var
    thing: GitThing
  result = release

  # if there's no way to peel it, just bail
  if project.dist != Git or result.kind != Tag:
    return

  # else, look up the reference
  withGit:
    if grcOk == lookupThing(thing, project.repo, result.reference):
      result = newRelease($thing.oid, operator = Tag)
    else:
      debug &"unable to find release reference `{result.reference}`"

proc peelRelease*(project: Project): Release =
  result = project.peelRelease(project.release)

iterator matchingReleases(requirement: Requirement; head = "";
                        tags: GitTagTable = nil): Release =
  ## yield releases that satisfy the requirement, using the head and tags
  case requirement.release.kind:
  of Tag:
    let reference = requirement.release.reference
    # recognize "head" as matching a provided head oid
    if reference.toLowerAscii == "head":
      # if it exists, i mean
      if head != "":
        yield newRelease(head, operator = Tag)
    else:
      # if we have tags to work with, then we try to match
      # against the tag and include the hash of the tag's oid
      if tags != nil:
        # this could be looking for `head`, by the way...
        if tags.hasKey(reference):
          if reference.toLowerAscii != "head":
            yield newRelease($tags[reference].oid, operator = Tag)
          else:
            debug "found `head` in the tags table"
        # now see if the specified reference matches a tag
        for name, thing in tags.pairs:
          if reference.toLowerAscii == $thing.oid:
            yield newRelease($thing.oid, operator = Tag)
        # we won't actually lookup a missing reference here; that really
        # should be done in a proc that has access to the project
  else:
    # we just iterate over all the tags and see any can be
    # converted to a version which satisfies the requirement
    if tags != nil:
      for name, thing in tags.pairs:
        let parsed = name.parseVersionLoosely
        if parsed.isNone:
          debug &"could not parse tag `{name}`"
          continue
        if requirement.isSatisfiedBy(parsed.get):
          yield newRelease($thing.oid, operator = Tag)

iterator symbolicMatch*(project: Project; req: Requirement): Release =
  ## see if a project can match a given requirement symbolically
  if project.dist == Git:
    if project.tags == nil:
      warn &"i wanted to examine tags for {project} but they were empty"
      raise newException(Defect, "seems like a programmer error to me")
    let
      gotHead = project.getHeadOid
      head = if gotHead.isSome: $gotHead.get else: ""
    for release in req.matchingReleases(head = head, tags = project.tags):
      debug &"release match {release} for {req}"
      yield release
    # here we will try to lookup any random reference requirement, just in case
    #
    # this currently could duplicate a release emitted above, but that's okay
    if req.release.kind == Tag:
      var thing: GitThing
      if grcOk == lookupThing(thing, project.repo, req.release.reference):
        yield newRelease($thing.oid, operator = Tag)
        debug &"found {req.release.reference} in {project}"
      else:
        debug &"could not find {req.release.reference} in {project}"
  else:
    debug &"without a repo for {project.name}, i cannot match {req}"
    # if we don't have any tags or the head, it's a simple test
    if req.isSatisfiedBy(project.release):
      yield project.release

proc symbolicMatch*(project: Project; req: Requirement; release: Release): bool =
  ## convenience
  let release = project.peelRelease(release)
  for match in project.symbolicMatch(req):
    result = match == release
    if result:
      break

proc symbolicMatch*(project: Project; req: Requirement): bool =
  ## convenience
  for match in project.symbolicMatch(req):
    result = true
    break

proc isSatisfiedBy(req: Requirement; project: Project; release: Release): bool =
  result = true
  block satisfied:
    if req.release.kind == Tag:
      # the requirement is for a particular tag...
      # compare tags, head, and versions
      result = project.symbolicMatch(req, release)
      debug &"project symbolic match {result} {req}"
      break satisfied
    if release.isSpecific:
      # try to use our release
      result = req.isSatisfiedBy newRelease(release.specifically)
      debug &"release {release} match {result} {req}"
      if result:
        break satisfied
    # maybe there's a scenario where we can retrieve a tag that isn't our
    # release, but does match the requirement?
    result = project.symbolicMatch(req)
    debug &"release {release} symbolic match {result} {req}"
    if result:
      break satisfied

proc isSatisfiedBy(req: Requirement; project: Project): bool =
  ## true if a requirement is satisfied by the given project
  # first, check that the identity matches
  if project.name == req.identity:
    result = true
  elif req.isUrl:
    let
      url = req.toUrl
    if url.isSome:
      let
        x = project.url.convertToGit
        y = url.get.convertToGit
      result = x == y or bareUrlsAreEqual(x, y)
  # if the name doesn't match, let's just bomb early
  if not result:
    return
  # now we need to confirm that the version will work
  block:
    if req.release.kind == Tag:
      # the requirement is for a particular tag...
      # compare tags, head, and versions
      result = project.symbolicMatch(req)
      debug &"project symbolic match {result} {req}"
      break
    if project.release.isSpecific:
      # try to use our release
      result = req.isSatisfiedBy newRelease(project.release.specifically)
      debug &"project release match {result} {req}"
      if result:
        break
    result = project.symbolicMatch(req)
    # maybe a different tag in the project will match?
    debug &"project symbolic match {result} {req}"
    if result:
      break
    if project.version.isValid:
      # fallback to the version indicated by nimble
      result = req.isSatisfiedBy newRelease(project.version)
      debug &"project version match {result} {req}"

proc get*[K: Requirement, V](group: Group[K, V]; key: K): V =
  ## fetch a package from the group using style-insensitive lookup
  result = group.table[key]

proc mget*[K: Requirement, V](group: var Group[K, V]; key: K): var V =
  ## fetch a package from the group using style-insensitive lookup
  result = group.table[key]

proc addName(dependency: var Dependency; name: string) =
  ## add an import name to the dependency, as might be used in code
  let
    package = name.importName
  if package notin dependency.names:
    dependency.names.add package

proc add(dependency: var Dependency; package: Package) =
  ## add a package to the dependency
  if package.url notin dependency.packages:
    dependency.packages.add package.url, package
  dependency.addName package.importName

proc add(dependency: var Dependency; url: Uri) =
  ## add a url (as a package) to the dependency
  dependency.add newPackage(url = url)

proc add(dependency: var Dependency; packages: PackageGroup) =
  ## add a group of packages to the dependency
  for package in packages.values:
    dependency.add package

proc add(dependency: var Dependency; directory: string; project: Project) =
  ## add a local project in the given directory to an existing dependency
  if dependency.projects.hasKey(directory):
    raise newException(Defect, "attempt to duplicate project dependency")
  dependency.projects.add directory, project
  dependency.addName project.name
  # this'll help anyone sniffing around thinking packages precede projects
  dependency.add project.asPackage

proc newDependency*(project: Project): Dependency =
  ## convenience to form a new dependency on a specific project
  let
    requirement = newRequirement(project.name, Equal, project.release)
  result = newDependency(requirement)
  result.add project.repo, project

proc mergeContents(existing: var Dependency; dependency: Dependency): bool =
  ## combine two dependencies and yield true if a new project is added
  # adding the packages as a group will work
  existing.add dependency.packages
  # add projects according to their repo
  for directory, project in dependency.projects.pairs:
    if directory in existing.projects:
      continue
    existing.projects.add directory, project
    result = true

proc addName(group: var DependencyGroup; req: Requirement; dep: Dependency) =
  ## add any import names from the dependency into the dependency group
  for directory, project in dep.projects.pairs:
    let name = project.importName
    if name notin group.imports:
      group.imports[project.importName] = directory
    elif group.imports[name] != directory:
      warn &"name collision for import `{name}`:"
      for path in [directory, group.imports[name]]:
        warn &"\t{path}"

proc add*(group: var DependencyGroup; req: Requirement; dep: Dependency) =
  group.table.add req, dep
  group.addName req, dep

proc addedRequirements(dependencies: var DependencyGroup;
                       dependency: var Dependency): bool =
  ## true if the addition of a dependency added new requirements to
  ## the dependency group
  let
    required = dependency.requirement
  var
    existing: Dependency

  # look for an existing dependency to merge into
  block found:
    # check to see if an existing project will work
    for req, dep in dependencies.mpairs:
      for directory, project in dep.projects.pairs:
        if required.isSatisfiedBy(project):
          existing = dep
          break found
    # failing that, check to see if an existing package matches
    for req, dep in dependencies.mpairs:
      for url, package in dep.packages.pairs:
        if package.url in dependency.packages:
          existing = dep
          break found
    # found nothing; install the dependency in the group
    dependencies.add required, dependency
    # we've added requirements we can analyze only if projects exist
    result = dependency.projects.len > 0

  # if we found a good merge target, then merge our existing dependency
  if existing != nil:
    result = existing.mergeContents dependency
    # point to the merged dependency
    dependency = existing

proc pathForName*(dependencies: DependencyGroup; name: string): Option[string] =
  ## try to retrieve the directory for a given import
  if dependencies.imports.hasKey(name):
    result = dependencies.imports[name].some

proc projectForPath*(dependencies: DependencyGroup; path: string): Project =
  ## retrieve a project from the dependencies using its path
  for dependency in dependencies.values:
    if dependency.projects.hasKey(path):
      result = dependency.projects[path]
      break

proc projectForName*(group: DependencyGroup; name: string): Option[Project] =
  ## try to retrieve a project given an import name
  let
    path = group.pathForName(name)
  if path.isNone:
    return
  result = group.projectForPath(path.get).some

proc isHappy*(dependency: Dependency): bool =
  ## true if the dependency is being met successfully
  result = dependency.projects.len > 0

proc isHappyWithVersion*(dependency: Dependency): bool =
  ## true if the dependency is happy with the version of the project
  for project in dependency.projects.values:
    let
      req = dependency.requirement
      peeled = project.peelRelease
    result = req.isSatisfiedBy(project, project.release)
    result = result or req.isSatisfiedBy(project, peeled)
    result = result or req.isSatisfiedBy(project, newRelease(project.version))
    if result:
      break

proc resolveDependency*(project: Project;
                        projects: ProjectGroup;
                        packages: PackageGroup;
                        requirement: Requirement): Dependency =
  ## filter all we know about the environment, a requirement, and the
  ## means by which we may satisfy it, into a single object
  result = newDependency(requirement)
  block success:

    # 1. is it a directory?
    for directory, available in projects.pairs:
      if not requirement.isSatisfiedBy(available):
        continue
      debug &"{available} satisfies {requirement}"
      result.add directory, available

    # seems like we found some viable deps info locally
    if result.isHappy:
      break success

    # 2. is it in packages?
    let matches = packages.matching(requirement)
    result.add(matches)
    if matches.len > 0:
      break success

    # 3. all we have is a url
    if requirement.isUrl:
      let findurl = requirement.toUrl(packages)
      if findurl.isSome:
        # if it's a url but we couldn't match it, add it to the result anyway
        result.add findurl.get
        break success

    let emsg = &"dunno where to get requirement {requirement}" # noqa
    raise newException(ValueError, emsg)

proc isUsing*(dependencies: DependencyGroup; target: Target;
              outside: Dependency = nil): bool =
  ## true if the target points to a repo we're importing
  block found:
    for requirement, dependency in dependencies.pairs:
      if dependency == outside:
        continue
      for directory, project in dependency.projects.pairs:
        if directory == target.repo:
          result = true
          break found
  when defined(debug):
    debug &"is using {target.repo}: {result}"

proc resolveDependencies*(project: var Project;
                          projects: var ProjectGroup;
                          packages: PackageGroup;
                          dependencies: var DependencyGroup): bool =
  ## resolve a project's dependencies recursively;
  ## store result in dependencies

  # assert a usable config
  assert project.cfg != nil

  if Flag.Quiet notin dependencies.flags:
    info &"{project.cuteRelease:>8} {project.name:>12}   {project.releaseSummary}"

  result = true

  let
    findReqs = project.determineDeps
  if findReqs.isNone:
    warn &"no requirements found for {project}"
    return

  let
    requires = findReqs.get
  for requirement in requires.values:
    if requirement.isVirtual:
      continue
    if requirement in dependencies:
      continue
    var resolved = project.resolveDependency(projects, packages, requirement)
    case resolved.packages.len:
    of 0:
      warn &"unable to resolve requirement `{requirement}`"
      result = false
      continue
    of 1:
      discard
    else:
      project.reportMultipleResolutions(requirement, resolved.packages)

    # if the addition of the resolution is not novel, move along
    if not dependencies.addedRequirements(resolved):
      continue

    # else, we'll resolve dependencies introduced in any new projects
    #
    # note: we're using project.cfg and project.repo as a kind of scope
    for recurse in resolved.projects.asFoundVia(project.cfg, project.repo):
      # if one of the existing dependencies is using the same project, then
      # we won't bother to recurse into it and process its requirements
      if dependencies.isUsing(recurse.nimble, outside = resolved):
        continue
      result = result and recurse.resolveDependencies(projects, packages,
                                                      dependencies)

proc getOfficialPackages(project: Project): PackagesResult =
  result = getOfficialPackages(project.nimbleDir)

proc resolveDependencies*(project: var Project;
                          dependencies: var DependencyGroup): bool =
  ## entrance to the recursive dependency resolution
  var
    packages: PackageGroup
    projects = project.childProjects

  let
    findPacks = project.getOfficialPackages
  if not findPacks.ok:
    packages = newPackageGroup()
  else:
    packages = findPacks.packages

  result = project.resolveDependencies(projects, packages, dependencies)
