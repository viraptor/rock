import ../frontend/Token
import Visitor, Statement, Expression, Node, FunctionDecl, FunctionCall,
       VariableAccess, VariableDecl, AddressOf, ArrayAccess, If,
       BinaryOp, Cast
import tinker/[Response, Resolver, Trail]

Return: class extends Statement {

    expr: Expression
    
    init: func ~ret (.token) {
        init(null, token)
    }
    
    init: func ~retWithExpr (=expr, .token) {
        super(token)
    }
    
    accept: func (visitor: Visitor) { visitor visitReturn(this) }
    
    resolve: func (trail: Trail, res: Resolver) -> Response {
        
        if(!expr) return Responses OK
        
        {
            trail push(this)
            response := expr resolve(trail, res)
            trail pop(this)
            if(!response ok()) {
                return response
            }
        }
        
        idx := trail find(FunctionDecl)
        if(idx != -1) {
            fDecl := trail get(idx) as FunctionDecl
            retType := fDecl getReturnType()
            if(!retType isResolved()) {
                return Responses LOOP
            }
            
            if(fDecl getReturnType() isGeneric()) {
                if(expr getType() == null || !expr getType() isResolved()) {
                    res wholeAgain(this, "expr type is unresolved"); return Responses OK
                }
                
                returnAcc := VariableAccess new(fDecl getReturnArg(), token)
                
                if1 := If new(returnAcc, token)
                
                if(expr hasSideEffects()) {
                    vdfe := VariableDecl new(null, generateTempName("returnVal"), expr, expr token)
                    if(!trail peek() addBefore(this, vdfe)) {
                        token throwError("Couldn't add the vdfe before the generic return in a %s! trail = %s" format(trail peek() as Node class name, trail toString()))
                    }
                    expr = VariableAccess new(vdfe, vdfe token)
                }
                
                ass := BinaryOp new(returnAcc, expr, OpTypes ass, token)
                if1 getBody() add(ass)
                
                if(!trail peek() addBefore(this, if1)) {
                    token throwError("Couldn't add the assignment before the generic return in a %s! trail = %s" format(trail peek() as Node class name, trail toString()))
                }
                expr = null
                
                res wholeAgain(this, "Turned into an assignment")
                //return Responses OK
                return Responses LOOP
            }
            
            if(expr != null) {
                if(expr getType() == null || !expr getType() isResolved()) {
                    res wholeAgain(this, "Need info about the expr type")
                    return Responses OK
                }
                if(!retType getName() toLower() equals("void") && !retType equals(expr getType())) {
                    // TODO: add checking to see if the types are compatible
                    expr = Cast new(expr, retType, expr token)
                }
            }
        }
        
        return Responses OK
        
    }

    toString: func -> String { expr == null ? "return" : "return " + expr toString() }
    
    replace: func (oldie, kiddo: Node) -> Bool {
        if(expr == oldie) {
            expr = kiddo
            return true
        }
        
        return false
    }

}


