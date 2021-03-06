import io/File, text/EscapeSequence
import structs/[HashMap, ArrayList, List, OrderedMultiMap]
import ../frontend/[Token, SourceReader, BuildParams, PathList, AstBuilder]
import ../utils/FileUtils
import Node, FunctionDecl, Visitor, Import, Include, Use, TypeDecl,
       FunctionCall, Type, Declaration, VariableAccess, OperatorDecl,
       Scope, NamespaceDecl, BaseType, FuncType
import tinker/[Response, Resolver, Trail]

Module: class extends Node {

    path, fullName, simpleName, packageName, underName, pathElement : String
    main := false

    types      := OrderedMultiMap<String, TypeDecl> new()
    functions  := OrderedMultiMap<String, FunctionDecl> new()
    operators  := ArrayList<OperatorDecl> new()

    includes   := ArrayList<Include> new()
    imports    := ArrayList<Import> new()
    namespaces := HashMap<String, NamespaceDecl> new()
    uses       := ArrayList<Use> new()

    funcTypesMap := HashMap<String, FuncType> new()

    body       := Scope new()

    lastModified : Long

    params: BuildParams
    
    init: func ~module (.fullName, =pathElement, =params, .token) {
        super(token)
        this path = fullName clone() replace('/', File separator)
        this fullName = fullName replace(File separator, '/')
        idx := this fullName lastIndexOf('/')

        match idx {
            case -1 =>
                simpleName = this fullName clone()
                packageName = ""
            case =>
                simpleName = this fullName substring(idx + 1)
                packageName = this fullName substring(0, idx)
        }

        underName = sanitize(this fullName clone())
        packageName = sanitize(packageName)
    }

    getLoadFuncName: func -> String { getUnderName() + "_load" }
    getFullName:     func -> String { fullName }
    getUnderName:    func -> String { underName }
    getPathElement:  func -> String { pathElement }
    getSourceFolderName: func -> String {
        File new(File new(getPathElement()) getAbsolutePath()) name()
    }

    addFuncType: func (hashName: String, funcType: FuncType) {
        if(!funcTypesMap contains(hashName)) {
            funcTypesMap put(hashName, funcType)
        }
    }

    sanitize: func(str: String) -> String {
        result := str clone()
        for(i in 0..result length()) {
            current := result[i]
            if(!current isAlphaNumeric()) {
                result[i] = '_'
            }
        }
        if(!result[0] isAlpha()) result = '_' + result
        result
    }

    addFunction: func (fDecl: FunctionDecl) {
        functions put(TypeDecl hashName(fDecl), fDecl)
    }

    addType: func (tDecl: TypeDecl) {
        old := types get(tDecl name) as TypeDecl
        if(old != null) {
            tDecl token printMessage("Redefinition of type %s" format(tDecl name), "[ERROR]")
            old   token throwError("...first definition was here: ")
        }
        
        types put(tDecl name, tDecl)
        if(tDecl getMeta()) types put(tDecl getMeta() name, tDecl getMeta())
    }

    addOperator: func (oDecl: OperatorDecl) {
        operators add(oDecl)
    }

    addImport: func (imp: Import) {
        imports add(imp)
    }

    addInclude: func (inc: Include) {
        includes add(inc)
    }

    addNamespace: func (nDecl: NamespaceDecl) {
        namespaces put(nDecl getName(), nDecl)
    }
    
    addUse: func (use1: Use) {
        uses add(use1)
    }

    getOperators: func -> List<OperatorDecl> { operators }
    getTypes:     func -> HashMap<String, TypeDecl>  { types }
    getUses:      func -> List<Use>          { uses }

    accept: func (visitor: Visitor) { visitor visitModule(this) }

    getPath: func ~full -> String { path }

    getPath: func (suffix: String) -> String {
        last := (File new(pathElement) name())
        return (last + File separator) + fullName replace('/', File separator) + suffix
    }

    getParentPath: func -> String {
        // FIXME that's sub-optimal
        fileName := pathElement + File separator + fullName + ".ooc"
        parentPath := File new(fileName) parent() path
        return parentPath
    }

    /** return global (e.g. non-namespaced) imports */
    getGlobalImports: func -> List<Import> { imports }

    /** return all imports, including those in namespaces */
    getAllImports: func -> List<Import> {
        if(namespaces isEmpty()) return imports

        list := ArrayList<Import> new()
        list addAll(getGlobalImports())
        for(namespace in namespaces)
            list addAll(namespace getImports())
        return list
    }

    resolveAccess: func (access: VariableAccess, res: Resolver, trail: Trail) -> Int {

        //printf("Looking for %s in %s\n", access toString(), toString())

        // TODO: optimize by returning as soon as the access is resolved
        resolveAccessNonRecursive(access, res, trail)

        for(imp in getGlobalImports()) {
            imp getModule() resolveAccessNonRecursive(access, res, trail)
        }

        namespace := namespaces get(access getName())
        if(namespace != null) {
            //printf("resolved access %s to namespace %s!\n", access getName(), namespace toString())
            access suggest(namespace)
        }
        
        0

    }

    resolveAccessNonRecursive: func (access: VariableAccess, res: Resolver, trail: Trail) -> Int {

        ref := null as Declaration

        for(f in functions) {
            if(f name == access name) {
                access suggest(f)
            }
        }

        ref = types get(access name)
        if(ref != null && access suggest(ref)) {
            return
        }

        // That's actually the only place we want to resolve variables from the
        // body - precisely because they're global
        body resolveAccess(access, res, trail)

        0

    }
    
    resolveCall: func (call: FunctionCall, res: Resolver, trail: Trail) -> Int {
        if(call isMember()) {
            return // hmm no member calls for us
        }
        
        resolveCallNonRecursive(call, res)
        
        for(imp in getGlobalImports()) {
            imp getModule() resolveCallNonRecursive(call, res)
        }
        
        0
    }
    
    resolveCallNonRecursive: func (call: FunctionCall, res: Resolver) {
        
        //printf(" >> Looking for function %s in module %s!\n", call name, fullName)
        fDecl : FunctionDecl = null
        fDecl = functions get(TypeDecl hashName(call name, call suffix))
        if(fDecl) {
            call suggest(fDecl)
        }
        
        for(fDecl in functions) {
            if(fDecl getName() == call getName() && (call getSuffix() == null || call getSuffix() == fDecl getSuffix())) {
                if(call debugCondition()) printf("Suggesting fDecl %s for call %s\n", fDecl toString(), call toString())
                call suggest(fDecl)
            }
        }
        
    }

    resolveType: func (type: BaseType) {

        ref : Declaration = null

        ref = types get(type name)
        if(ref != null && type suggest(ref)) {
            return
        }

        for(imp in getGlobalImports()) {
            //printf("Looking in import %s\n", imp path)
            ref = imp getModule() types get(type name)
            if(ref != null && type suggest(ref)) {
                //("Found type " + name + " in " + imp getModule() fullName)
                break
            }
        }

    }

    /**
     * Parse the imports of this module.
     * 
     * If resolver is non-null, it means there's a new import that
     * we expect to add to the resolvers list.
     */
    parseImports: func (resolver: Resolver) {

        for(imp: Import in getAllImports()) {
            if(imp getModule() != null) continue
            
            impPath = null, impElement = null : File
            path = null: String
            AstBuilder getRealImportPath(imp, this, params, path&, impPath&, impElement&)
            if(impPath == null) {
                imp token throwError("Module not found in sourcepath " + imp path)
            }

            //println("Trying to get "+impPath path+" from cache")
            cached : Module = null
            cached = AstBuilder cache get(impPath path)

            impLastModified := File new(impPath path) lastModified()

            if(cached == null || File new(impPath path) lastModified() > cached lastModified) {
                if(cached) {
                    printf("%s has been changed, recompiling... (%d vs %d), impPath = %s", path, File new(impPath path) lastModified(), cached lastModified, impPath path);
                }
                //printf("impElement path = %s, impPath = %s\n", impElement path, impPath path)
                cached = Module new(path[0..(path length()-4)], impElement path, params, nullToken)
                cached token = Token new(0, 0, cached)
                if(resolver != null) {
                    resolver addModule(cached)
                }
                imp setModule(cached)
                cached lastModified = impLastModified
                AstBuilder new(impPath path, cached, params)
                cached parseImports(resolver)
            }
            imp setModule(cached)
        }
    }

    resolve: func (trail: Trail, res: Resolver) -> Response {

        finalResponse := Responses OK

        trail push(this)
        
        {
            response := body resolve(trail, res)
            if(!response ok()) {
                if(res params veryVerbose) printf("response of body = %s\n", response toString())
                finalResponse = response
            }
        }
        
        for(tDecl in types) {
            if(tDecl isResolved()) continue
            response := tDecl resolve(trail, res)
            if(!response ok()) {
                if(res params veryVerbose) printf("response of tDecl %s = %s\n", tDecl toString(), response toString())
                finalResponse = response
            }
        }

        for(fDecl in functions) {
            if(fDecl isResolved()) continue
            response := fDecl resolve(trail, res)
            if(!response ok()) {
                if(res params veryVerbose) printf("response of fDecl %s = %s\n", fDecl toString(), response toString())
                finalResponse = response
            }
        }

        for(oDecl in operators) {
            if(oDecl isResolved()) continue
            response := oDecl resolve(trail, res)
            if(!response ok()) {
                if(res params veryVerbose) printf("response of oDecl %s = %s\n", oDecl toString(), response toString())
                finalResponse = response
            }
        }

        for(inc in includes) {
            if(inc getVersion() != null && !inc getVersion() resolve() ok()) return Responses LOOP
        }

        trail pop(this)

        return finalResponse
    }

    toString: func -> String {
        class name + ' ' + fullName
    }

    replace: func (oldie, kiddo: Node) -> Bool { false }

    isScope: func -> Bool { true }

}
