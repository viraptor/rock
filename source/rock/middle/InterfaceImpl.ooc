import ../frontend/Token
import ClassDecl, Type, FunctionDecl, TypeDecl
import structs/HashMap
import tinker/[Response, Resolver, Trail]

FunctionAlias: class {
    
    key, value: FunctionDecl
    init: func ~funcAlias(=key, =value) {}
    
    toString: func -> String { "alias %s <=> %s" format(key toString(), value toString()) }
    
}

InterfaceImpl: class extends ClassDecl {
    
    impl: TypeDecl
    aliases := HashMap<String, FunctionAlias> new()
    
    init: func ~interf(.name, interfaceType: Type, =impl, .token) {
        super(name, interfaceType, token)
        module      = impl module
        meta module = impl module
    }
    
    getAliases: func -> HashMap<String, FunctionDecl> { aliases }
    
    resolve: func (trail: Trail, res: Resolver) -> Response {
        
        if(!super(trail, res) ok()) return Responses LOOP
        
        ref := superType getRef() as TypeDecl
        if(ref == null) return Responses LOOP
        
        // done already.
        if(aliases size() == ref getMeta() getFunctions() size()) return Responses OK
        
        for(key: FunctionDecl in ref getMeta() getFunctions()) {
            hash := hashName(key)
            alias := aliases get(hash)
            if(alias == null) {
                //FIXME: smarter strategy needed here to match functions - also, check signatures
                finalScore : Int
                value := impl getMeta() getFunction(key getName(), key getSuffix(), null, true, finalScore&)
                if(finalScore == -1) {
                    res wholeAgain(this, "Not finished checking every function is implemented")
                    return Responses OK
                }
                if(value == null) {
                    if(impl instanceOf(ClassDecl) && impl as ClassDecl isAbstract) {
                        // relay unimplemented interface methods into an abstract class
                        value = FunctionDecl new(key getName(), key token)
                        value suffix = key suffix
                        value args = key args clone()
                        value returnType = key returnType
                        value setAbstract(true)
                        impl addFunction(value)
                    } else {
                        // but err on concrete class, cause they should implement everything
                        token throwError("%s must implement function %s, from interface %s\n" format(
                            impl getName(), key toString(), superType toString()))
                    }
                }
                aliases put(hash, FunctionAlias new(key, value))
            }
        }
        
        return Responses OK
        
    }
    
}
