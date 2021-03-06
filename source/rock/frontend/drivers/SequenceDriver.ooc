import io/File, os/Process, text/Buffer
import structs/[List, ArrayList, HashMap]
import ../[BuildParams, Target]
import ../compilers/AbstractCompiler
import ../../middle/[Module, UseDef]
import Driver

SourceFolder: class {
    name: String
    modules := ArrayList<Module> new()
    
    init: func (=name) {}
}

SequenceDriver: class extends Driver {

    init: func (.params) { super(params) }

	compile: func (module: Module) -> Int {
		
		copyLocalHeaders(module, params, ArrayList<Module> new())    
		
		if(params verbose) {
			("Sequence driver, using " + params sequenceThreads + " thread(s).") println()
		}
		
		toCompile := collectDeps(module, HashMap<String, SourceFolder> new(), ArrayList<String> new())
        
        oPaths := ArrayList<String> new()
		
        for(sourceFolder in toCompile) {
            if(params verbose) printf("Building source folder %s\n", sourceFolder name)
            buildSourceFolder(sourceFolder, oPaths)
        }
		
		if(params link) {
			
			initCompiler(params compiler)
            
			if(params linker != null) params compiler setExecutable(params linker)    
			
			for(oPath in oPaths) {
				params compiler addObjectFile(oPath)    
			}
			
            for(define in params defines) {
                params compiler defineSymbol(define)
            }
            for(dynamicLib in params dynamicLibs) {
                params compiler addDynamicLibrary(dynamicLib)
            }
            for(incPath in params incPath getPaths()) {
                params compiler addIncludePath(incPath getPath())
            }
            for(additional in params additionals) {
                params compiler addObjectFile(additional)
            }
			for(libPath in params libPath getPaths()) {
				params compiler addLibraryPath(libPath getAbsolutePath())    
			}

			if(params binaryPath != "") {
                params compiler setOutputPath(params binaryPath)
            } else {
                params compiler setOutputPath(module simpleName)
            }
            
            libs := getFlagsFromUse(module)
            for(lib in libs) {
                params compiler addObjectFile(lib)
            }
			
			if(params enableGC) {
                params compiler addDynamicLibrary("pthread")
                if(params dynGC) {
                    params compiler addDynamicLibrary("gc")
                } else {
                    arch := params arch equals("") ? Target getArch() : params arch
                    libPath := "libs/" + Target toString(arch) + "/libgc.a"
                    params compiler addObjectFile(File new(params distLocation, libPath) path)
                }
            }
			if(params verbose) params compiler getCommandLine() println()
	
			code := params compiler launch()    
			
			if(code != 0) {
                fprintf(stderr, "C compiler failed, aborting compilation process\n")
				return code
			}
		
		}
		
		if(params outlib != null) {
			toCompile := collectDeps(module, HashMap<String, SourceFolder> new(), ArrayList<String> new())
            modules := ArrayList<Module> new()
            
			for(sourceFolder in toCompile) {
                modules addAll(sourceFolder modules)
			}
            
            if(params verbose) "Building archive %s with all object files." format(params outlib) println()
            buildArchive(params outlib, modules)
		}
		
		
		return 0    
		
	}
    
    /**
       Build a source folder into object files or a static library
     */
    buildSourceFolder: func (sourceFolder: SourceFolder, objectFiles: List<String>) {
        
        outlib := File new(File new(".libs"), "%s-%s.a" format(sourceFolder name, Target toString()))
        
        // if lib-caching, we compile every object file to a .a static lib
        if(params libcache) {
            objectFiles add(outlib getPath())
        
            if(outlib exists()) {
                good := true
                lastModified := outlib lastModified()
                for(module in sourceFolder modules) {
                    file := File new(module pathElement + File separator + module path + ".ooc")
                    if(params veryVerbose) printf("Comparing %ld vs %ld, ie. %s vs %s\n", lastModified, file lastModified(), outlib path, file path)
                    if(lastModified < file lastModified()) {
                        good = false
                        if(params veryVerbose) printf("Recompiling because of %s\n", module fullName)
                        break
                    }
                }
                if(good) return
            }
        }
        
        oPaths := ArrayList<String> new()
        
        for(currentModule in sourceFolder modules) {
            
            initCompiler(params compiler)    
            params compiler setCompileOnly()
            
            path := File new(params outPath, currentModule getPath("")) getPath()
            oPath := path + ".o"    
            cPath := path + ".c"    
            oPaths add(oPath)
            
            cFile := File new(cPath)
            oFile := File new(oPath)
            
            if(cFile lastModified() > oFile lastModified()) {
                
                params compiler addObjectFile(cPath)    
                params compiler setOutputPath(oPath)    
                
                params compiler addIncludePath(File new(params distLocation, "libs/headers/") getPath())
                params compiler addIncludePath(params outPath getPath())
                        
                for(define in params defines) {
                    params compiler defineSymbol(define)
                }
                for(dynamicLib in params dynamicLibs) {
                    params compiler addDynamicLibrary(dynamicLib)
                }
                for(incPath in params incPath getPaths()) {
                    params compiler addIncludePath(incPath getPath())
                }
                for(compilerArg in params compilerArgs) {
                    params compiler addObjectFile(compilerArg)
                }

                libs := getFlagsFromUse(sourceFolder)
                for(lib in libs) {
                    params compiler addObjectFile(lib)
                }
                
                if(params verbose) params compiler getCommandLine() println()
                
                code := params compiler launch()    
                    
                if(code != 0) {
                    fprintf(stderr, "C compiler failed, aborting compilation process\n")
                    return code 
                }
                
            } else {
                if(params veryVerbose) printf("Skipping %s, unchanged source.\n", cPath)
            }
            
        }
        
        if(params libcache) {
            // now build a static library
            outlib parent() mkdirs()
            if(params verbose) printf("Saving to library %s\n", outlib getPath())
            buildArchive(outlib getPath(), sourceFolder modules)
        } else {
            if(params verbose) printf("Lib caching disabled, building from .o files\n")
            objectFiles addAll(oPaths)
        }
        
    }
    
    /**
       Get all the flags from uses in 
     */
    getFlagsFromUse: func ~sourceFolder (sourceFolder: SourceFolder) -> List<String> {
        
        flagsDone := ArrayList<String> new()
        usesDone := ArrayList<UseDef> new() 
        
        for(module in sourceFolder modules) {
            for(use1 in module uses) {
                useDef := use1 getUseDef() 
                getFlagsFromUse(useDef, flagsDone, usesDone) 
            }
        }
        
        
        flagsDone
    }
    
    /**
       Build an archive named `outlib` from the .o files 
     */
    buildArchive: func (outlib: String, modules: List<Module>) {
        
        // TODO: make this platform-independant (for now it's a linux-friendly hack)
        args := ArrayList<String> new()
        args add("ar")      // ar = archive tool
        args add("rcs")     // r = insert files, c = create archive, s = create/update .o file index
        args add(outlib)
        
        for(dep in modules) {
            args add(File new(params outPath, dep getPath("")) getPath() + ".o")    
        }
        
        if(params verbose) {
            command := Buffer new()
            for(arg in args) {
                command append(arg) .append(" ")
            }
            command toString() println()
        }
        
        process := Process new(args)
        process getOutput() print() // not ideal, should redirect to stdin+stdout instead
        
    }

	initCompiler: func (compiler: AbstractCompiler) {
		compiler reset()
		
		if(params debug) params compiler setDebugEnabled()      
        params compiler addIncludePath(File new(params distLocation, "libs/headers/") getPath())
        params compiler addIncludePath(params outPath getPath())
		
		for(compilerArg in params compilerArgs) {
            params compiler addObjectFile(compilerArg)
        }
	}

    /**
       Collect all modules imported from `module`, sort them by SourceFolder,
       put them in `toCompile`, and return it.
     */
	collectDeps: func (module: Module, toCompile: HashMap<String, SourceFolder>, done: ArrayList<String>) -> HashMap<String, SourceFolder> {
		
        name := File new(File new(module getPathElement()) getAbsolutePath()) name()
        
        sourceFolder := toCompile get(name)
        if(sourceFolder == null) {
            sourceFolder = SourceFolder new(name)
            toCompile put(name, sourceFolder)
        }
        
		sourceFolder modules add(module)    
		done add(module getPath())
		
		for(import1 in module getAllImports()) {
			if(done contains(import1 getModule() getPath())) continue
			collectDeps(import1 getModule(), toCompile, done)    
		}
		
		return toCompile    
		
	}
	
}
