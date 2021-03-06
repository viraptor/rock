import ../frontend/[Token, BuildParams]
import Literal, Visitor, Type, Expression, FunctionCall, Block,
       VariableDecl, VariableAccess, Cast, Node, ClassDecl, TypeDecl, BaseType,
       Statement, IntLiteral, BinaryOp, Block, ArrayCreation, FunctionCall,
       FunctionDecl
import tinker/[Response, Resolver, Trail]
import structs/[List, ArrayList]
import text/Buffer

ArrayLiteral: class extends Literal {

    unwrapped := false
    elements := ArrayList<Expression> new()
    type : Type = null
    
    init: func ~arrayLiteral (.token) {
        super(token)
    }
    
    getElements: func -> List<Expression> { elements }
    
    accept: func (visitor: Visitor) { 
        visitor visitArrayLiteral(this)
    }

    getType: func -> Type { type }
    
    toString: func -> String {
        if(elements isEmpty()) return "[]"
        
        buffer := Buffer new()
        buffer append('[')
        isFirst := true
        for(element in elements) {
            if(isFirst) isFirst = false
            else        buffer append(", ")
            buffer append(element toString())
        }
        buffer append(']')
        buffer toString()
    }
    
    resolve: func (trail: Trail, res: Resolver) -> Response {
        
        readyToUnwrap := true
        
        // bitchjump casts and infer type from them, if they're there (damn you, j/ooc)
        {
            parentIdx := 1
            parent := trail peek(parentIdx)
            if(parent instanceOf(Cast)) {
                readyToUnwrap = false
                cast := parent as Cast
                parentIdx += 1
                grandpa := trail peek(parentIdx)
                
                if( (type == null || !type equals(cast getType())) &&
                    (cast getType() instanceOf(ArrayType) || cast getType() isPointer()) &&
                    (!cast getType() as SugarType inner isGeneric())) {
                    type = cast getType()
                    if(type != null) {
                        //if(res params veryVerbose) printf(">> Inferred type %s of %s by outer cast %s\n", type toString(), toString(), parent toString())
                        // bitchjump the cast
                        grandpa replace(parent, this)
                    }
                }
            }
            grandpa := trail peek(parentIdx + 1)
        }
        
        // infer type from parent function call, if any, and add an implicit cast
        {
            parent := trail peek()
            if(parent instanceOf(FunctionCall)) {
                fCall := parent as FunctionCall
                index := fCall args indexOf(this)
                if(index != -1) {
                    if(fCall getRef() == null) {
                        res wholeAgain(this, "Need call ref to infer type")
                        readyToUnwrap = false
                    } else {
                        targetType := fCall getRef() args get(index) getType()
                        if((type == null || !type equals(targetType)) &&
                           (!targetType instanceOf(SugarType) || !targetType as SugarType inner isGeneric())) {
                            cast := Cast new(this, targetType, token)
                            if(!parent replace(this, cast)) {
                                token throwError("Couldn't replace %s with %s in %s" format(toString(), cast toString(), parent toString()))
                            }
                            res wholeAgain(this, "Replaced with a cast")
                            return Responses OK
                        }
                    }
                }
            }
        }
        
        // resolve all elements
        trail push(this)
        for(element in elements) {
            response := element resolve(trail, res)
            if(!response ok()) {
                trail pop(this)
                return response
            }
        }
        trail pop(this)
        
        // if we still don't know our type, resolve from elements' innerTypes
        if(type == null) {
            innerType := elements first() getType()
            if(innerType == null || !innerType isResolved()) {
                res wholeAgain(this, "need innerType")
                return Responses OK
            }
            
            type = ArrayType new(innerType, IntLiteral new(elements size(), token), token)
            //if(res params veryVerbose) printf("Inferred type %s for %s\n", type toString(), toString())
        }
        
        if(type != null) {
            response := type resolve(trail, res)
            if(!response ok()) return response
        }
        
        if(readyToUnwrap && type instanceOf(ArrayType)) {
            return unwrapToArrayInit(trail, res)
        }
        
        return Responses OK
        
    }
    
    /**
        unwrap something like:
       
            array := [1, 2, 3]
        
        to something like:
       
            arrLit := [1, 2, 3] as Int*
            array := Int[3] new()
            memcpy(array data, arrLit, Int size * 3)
        
    */
    unwrapToArrayInit: func (trail: Trail, res: Resolver) -> Response {
        
        // set to true if a VDFE should become a simple VD with
        // explicit initialization in getDefaultsFunc()/getLoadFunc()
        // this happens when the order of initialization becomes
        // important, especially when casting an array literal to an ArrayList
        memberInitShouldMove := false
        
        arrType := type as ArrayType
        
        // check outer var-decl
        varDeclIdx := trail find(VariableDecl)
        if(varDeclIdx != -1) {
            memberDecl := trail get(varDeclIdx) as VariableDecl
            if(memberDecl getType() == null) {
                res wholeAgain(this, "need memberDecl type")
                return Responses OK
            }
        }
            
        // bitch-jump casts
        parentIdx := 1
        parent := trail peek(parentIdx)
        while(parent instanceOf(Cast)) {
            parentIdx += 1
            parent = trail peek(parentIdx)
        }
        
        vDecl : VariableDecl = null
        vAcc : VariableAccess = null
        
        if(parent instanceOf(VariableDecl)) {
            vDecl = parent as VariableDecl
            vAcc = VariableAccess new(vDecl, token)
            if(vDecl isMember()) {
                vAcc expr = vDecl isStatic() ? VariableAccess new(vDecl owner getNonMeta() getInstanceType(), token) : VariableAccess new("this", token)
            }
        } else {
            vDecl = VariableDecl new(null, generateTempName("arrLit"), token)
            vAcc = VariableAccess new(vDecl, token)
            if(vDecl isMember()) {
                vAcc expr = vDecl isStatic() ? VariableAccess new(vDecl owner getNonMeta() getInstanceType(), token) : VariableAccess new("this", token)
            }
            if(!trail addBeforeInScope(this, vDecl)) {
                grandpa := trail peek(parentIdx + 2)
                memberDecl := trail get(varDeclIdx) as VariableDecl
                
                if(grandpa instanceOf(ClassDecl)) {
                    cDecl := grandpa as ClassDecl
                    fDecl: FunctionDecl
                    if(memberDecl isStatic()) {
                        fDecl = cDecl getLoadFunc()
                    } else {
                        fDecl = cDecl getDefaultsFunc()
                    }
                    fDecl getBody() add(vDecl)
                    memberInitShouldMove = true
                } else {
                    token printMessage("Couldn't add %s before in scope." format(vDecl toString()), "ERROR")
                    Exception new(This, "Couldn't add, debugging") throw()
                }
            }
            if(!parent replace(this, vAcc)) {
                if(res fatal) {
                    token throwError("Couldn't replace %s with varAcc in %s" format(toString(), parent toString()))
                }
                res wholeAgain(this, "Trail is messed up, gotta loop.")
                return Responses OK
            }
        }

        vDecl setType(null)
        vDecl setExpr(ArrayCreation new(type as ArrayType, token))
        ptrDecl := VariableDecl new(null, generateTempName("ptrLit"), this, token)
        
        // add memcpy from C-pointer literal block
        block := Block new(token)
        
        // if varDecl is our immediate parent
        success := false
        if(trail size() - varDeclIdx == 1) {
            success = trail addAfterInScope(vDecl, block)
        } else {
            success = trail addBeforeInScope(this, block)
        }
        
        if(!success) {
            grandpa := trail get(varDeclIdx - 1)
            memberDecl := trail get(varDeclIdx) as VariableDecl
            
            if(grandpa instanceOf(ClassDecl)) {
                cDecl := grandpa as ClassDecl
                fDecl: FunctionDecl
                if(memberDecl isStatic()) {
                    fDecl = cDecl getLoadFunc()
                } else {
                    fDecl = cDecl getDefaultsFunc()
                }
                fDecl getBody() add(block)
                
                if(memberInitShouldMove) {
                    // now we should move the 'expr' of our VariableDecl into fDecl's body,
                    // because order matters here.
                    if(memberDecl getType() == null) memberDecl setType(memberDecl expr getType()) // fixate type
                    memberAcc := VariableAccess new(memberDecl, token)
                    memberAcc expr = memberDecl isStatic() ? VariableAccess new(memberDecl owner getNonMeta() getInstanceType(), token) : VariableAccess new("this", token)
                    
                    init := BinaryOp new(memberAcc, memberDecl expr, OpTypes ass, token)
                    fDecl getBody() add(init)
                    memberDecl setExpr(null)
                }
            } else {
                token throwError("Couldn't add block after %s in scope! trail = %s" format(vDecl toString(), trail toString()))
            }
        }
        
        block getBody() add(ptrDecl)
        
        innerTypeAcc := VariableAccess new(arrType inner, token)
        
        sizeExpr : Expression = (arrType expr ? arrType expr : VariableAccess new(vAcc, "length", token))
        copySize := BinaryOp new(sizeExpr, VariableAccess new(innerTypeAcc, "size", token), OpTypes mul, token)
        
        memcpyCall := FunctionCall new("memcpy", token)
        memcpyCall args add(VariableAccess new(vAcc, "data", token))
        memcpyCall args add(VariableAccess new(ptrDecl, token))
        memcpyCall args add(copySize)
        block getBody() add(memcpyCall)
        
        type = PointerType new(arrType inner, arrType token)
        
        return Responses LOOP
        
    }
    
    replace: func (oldie, kiddo: Node) -> Bool {
        elements replace(oldie, kiddo)
    }

}
