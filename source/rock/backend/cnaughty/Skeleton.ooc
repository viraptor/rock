import AwesomeWriter, ../../middle/[Visitor, Statement, ControlStatement]
import text/EscapeSequence, rock/frontend/BuildParams, io/File

Skeleton: abstract class extends Visitor {
    
    params: BuildParams
    module: Module
    
    hw, cw, fw, current: AwesomeWriter
    
    /** Write a line */
    writeLine: func (stat: Statement) {
        if(params debug && params lineDirectives) {
            if(!stat token module) stat token module = module
            
            current nl(). app("#line "). app(stat token getLineNumber() toString()). app(" \""). app(EscapeSequence escape(stat token getPath())). app("\"")
		}
        
        current nl(). app(stat)
        if(!stat instanceOf(ControlStatement))
            current app(';')
    }
    
}
