-- See Copyright Notice in ../LICENSE.txt
local ffi = require("ffi")
local asdl = require("asdl")
local List = asdl.List

-- LINE COVERAGE INFORMATION, must run test script with luajit and not terra to avoid overwriting coverage with old version
if false then
    local converageloader = loadfile("coverageinfo.lua")
    local linetable = converageloader and converageloader() or {}
    local function dumplineinfo()
        local F = io.open("coverageinfo.lua","w")
        F:write("return {\n")
        for k,v in pairs(linetable) do
            F:write("["..k.."] = "..v..";\n")
        end
        F:write("}\n")
        F:close()
    end
    local function debughook(event)
        local info = debug.getinfo(2,"Sl")
        if info.short_src == "src/terralib.lua" then
            linetable[info.currentline] = linetable[info.currentline] or 0
            linetable[info.currentline] = linetable[info.currentline] + 1
        end
    end
    debug.sethook(debughook,"l")
    -- make a fake ffi object that causes dumplineinfo to be called when
    -- the lua state is removed
    ffi.cdef [[
        typedef struct {} __linecoverage;
    ]]
    ffi.metatype("__linecoverage", { __gc = dumplineinfo } )
    _G[{}] = ffi.new("__linecoverage")
end

setmetatable(terra.kinds, { __index = function(self,idx)
    error("unknown kind accessed: "..tostring(idx))
end })

local T = asdl.NewContext()

T:Extern("Symbol", function(t) return terra.issymbol(t) end)
T:Extern("GlobalVar", function(t) return terra.isglobalvar(t) end)
T:Extern("Constant", function(t) return terra.isconstant(t) end)
T:Extern("LuaExprOrType",function(t) return terra.types.istype(t) or T.luaexpression:isclassof(t) end) -- temporary until eager typing is sorted out
T:Define [[
ident =     escapedident(luaexpression expression) # removed during specialization
          | namedident(string value)
          | symbolident(Symbol value) 

field = recfield(ident key, tree value)
      | listfield(tree value)
      
structbody = structentry(string key, luaexpression type)
           | structlist(structbody* entries)

param = unevaluatedparam(ident name, luaexpression? type) # removed during specialization
      | concreteparam(Type? type, string name, Symbol symbol)
      
functiondefu = (param* parameters, boolean is_varargs, LuaExprOrType? returntype, block body)
functiondef = (allocvar* parameters, boolean is_varargs, Type type, block body, table labels)
structdef = (luaexpression? metatype, structlist records)

ifbranch = (tree condition, block body)
attr = (boolean nontemporal, number? alignment, boolean isvolatile)

storelocation = (number index, tree value) # for struct cast, value uses structvariable

tree = 
     # trees that are introduced in parsing and are ...
     # removed during specialization
       luaexpression(function expression, boolean isexpression)
     # removed during typechecking
     | constructoru(field* records) #untyped version
     | selectu(tree value, ident field) #untyped version
     | method(tree value,ident name,tree* arguments) 
     | treelist(tree* trees)
     | fornumu(param variable, tree initial, tree limit, tree? step,block body) #untyped version
     | defvar(param* variables,  boolean hasinit, tree* initializers)
     | forlist(param* variables, tree iterator, block body)
     
     # introduced temporarily during specialization/typing, but removed after typing
     | luaobject(any value)
     | typedexpression(tree expression, table key)
     | setteru(function setter) # temporary node introduced and removed during typechecking to handle __update and __setfield
          
     # trees that exist after typechecking and handled by the backend:
     | var(string name, Symbol? symbol) #symbol is added during specialization
     | literal(any? value, Type type)
     | index(tree value,tree index)
     | apply(tree value, tree* arguments)
     | letin(tree* statements, tree* expressions, boolean hasstatements)
     | operator(string operator, tree* operands)
     | block(tree* statements)
     | assignment(tree* lhs,tree* rhs)
     | gotostat(ident label)
     | breakstat()
     | label(ident value)
     | whilestat(tree condition, block body)
     | repeatstat(tree* statements, tree condition)
     | fornum(allocvar variable, tree initial, tree limit, tree? step, block body)
     | ifstat(ifbranch* branches, block? orelse)
     | defer(tree expression)
     | select(tree value, number index, string fieldname) # typed version, fieldname for debugging
     | globalvar(string name, GlobalVar value)
     | constant(Constant value, Type type)
     | attrstore(tree address, tree value, attr attrs)
     | attrload(tree address, attr attrs)
     | debuginfo(string customfilename, number customlinenumber)
     | arrayconstructor(Type? oftype,tree* expressions)
     | vectorconstructor(Type? oftype,tree* expressions)
     | sizeof(Type oftype)
     | inlineasm(Type type, string asm, boolean volatile, string constraints, tree* arguments)
     | cast(Type to, tree expression, boolean explicit) # from is optional for untyped cast, will be removed eventually
     | allocvar(string name, Symbol symbol)
     | structcast(allocvar structvariable, tree expression, storelocation* entries)
     | constructor(tree* expressions)
     | returnstat(tree expression)
     | setter(tree setter, allocvar rhs) # handles custom assignment behavior, real rhs is first stored in 'rhs' and then the 'setter' expression uses it

Type = primitive(string type, number bytes, boolean signed)
     | pointer(Type type, number addressspace) unique
     | vector(Type type, number N) unique
     | array(Type type, number N) unique
     | functype(Type* parameters, Type returntype, boolean isvararg) unique
     | struct(string name)
     | niltype #the type of the singleton nil (implicitly convertable to any pointer type)
     | opaque #an type of unknown layout used with a pointer (&opaque) to point to data of an unknown type (i.e. void*)
     | error #used in compiler to squelch errors
     
]]
terra.irtypes = T

T.var.lvalue,T.globalvar.lvalue = true,true

-- temporary until we replace with asdl
local tokens = setmetatable({},{__index = function(self,idx) return idx end })

terra.isverbose = 0 --set by C api

local function dbprint(level,...) 
    if terra.isverbose >= level then
        print(...)
    end
end
local function dbprintraw(level,obj)
    if terra.isverbose >= level then
        terra.printraw(obj)
    end
end

--debug wrapper around cdef function to print out all the things being defined
local oldcdef = ffi.cdef
ffi.cdef = function(...)
    dbprint(2,...)
    return oldcdef(...)
end

-- TREE
function T.tree:is(value)
    return self.kind == value
end
 
function terra.printraw(self)
    local function header(t)
        local mt = getmetatable(t)
        if type(t) == "table" and mt and type(mt.__fields) == "table" then
            return t.kind or tostring(mt)
        else return tostring(t) end
    end
    local function isList(t)
        return type(t) == "table" and #t ~= 0
    end
    local parents = {}
    local depth = 0
    local function printElem(t,spacing)
        if(type(t) == "table") then
            if parents[t] then
                print(string.rep(" ",#spacing).."<cyclic reference>")
                return
            elseif depth > 0 and (terra.isfunction(t) or terra.isfunctiondefinition(t)) then
                return --don't print the entire nested function...
            end
            parents[t] = true
            depth = depth + 1
            for k,v in pairs(t) do
                local prefix
                if type(k) == "table" and not terra.issymbol(k) then
                    prefix = ("<table (mt = %s)>"):format(tostring(getmetatable(k)))
                else
                    prefix = tostring(k)
                end
                if k ~= "kind" and k ~= "offset" then
                    prefix = spacing..prefix..": "
                    if terra.types.istype(v) then --dont print the raw form of types unless printraw was called directly on the type
                        print(prefix..tostring(v))
                    else
                        print(prefix..header(v))
                        if isList(v) then
                            printElem(v,string.rep(" ",2+#spacing))
                        else
                            printElem(v,string.rep(" ",2+#prefix))
                        end
                    end
                end
            end
            depth = depth - 1
            parents[t] = nil
        end
    end
    print(header(self))
    if type(self) == "table" then
        printElem(self,"  ")
    end
end

local function newobject(ref,ctor,...) -- create a new object, copying the line/file info from the reference
    assert(ref.linenumber and ref.filename, "not a anchored object?")
    local r = ctor(...)
    r.linenumber,r.filename,r.offset = ref.linenumber,ref.filename,ref.offset
    return r
end

local function copyobject(ref,newfields) -- copy an object, extracting any new replacement fields from newfields table
    local class = getmetatable(ref)
    local fields = class.__fields
    assert(fields,"not a asdl object?")
    local function handlefield(i,...) -- need to do this with tail recursion rather than a loop to handle nil values
        if i == 0 then
            return newobject(ref,class,...)
        else
            local f = fields[i]
            local a = newfields[f.name] or ref[f.name]
            newfields[f.name] = nil
            return handlefield(i-1,a,...)
        end
    end
    local r = handlefield(#fields)
    for k,v in pairs(newfields) do
        error("unused field in copy: "..tostring(k))
    end
    return r
end
T.tree.copy = copyobject --support :copy directly on objects
function T.tree:aserror() -- a copy of this tree with an error type, used when unable to return a real value
    return self:copy{}:withtype(terra.types.error)
end

function terra.newanchor(depth)
    local info = debug.getinfo(1 + depth,"Sl")
    local body = { linenumber = info and info.currentline or 0, filename = info and info.short_src or "unknown" }
    return setmetatable(body,terra.tree)
end

function terra.istree(v) 
    return T.tree:isclassof(v)
end

-- END TREE

local function mkstring(self,begin,sep,finish)
    if sep == nil then
        begin,sep,finish = "",begin,""
    end
    return begin..table.concat(self:map(tostring),sep)..finish
end
terra.newlist = List
function terra.islist(l) return List:isclassof(l) end


-- CONTEXT
terra.context = {}
terra.context.__index = terra.context

function terra.context:isempty()
    return #self.stack == 0
end

function terra.context:begin(obj) --obj is currently only a funcdefinition
    obj.compileindex = self.nextindex
    obj.lowlink = obj.compileindex
    self.nextindex = self.nextindex + 1
    
    self.diagnostics:begin()
    
    table.insert(self.stack,obj)
    table.insert(self.tobecompiled,obj)
end

function terra.context:min(n)
    local curobj = self.stack[#self.stack]
    curobj.lowlink = math.min(curobj.lowlink,n)
end

local typeerrordebugcallback
function terra.settypeerrordebugcallback(fn)
    assert(type(fn) == "function")
    typeerrordebugcallback = fn
end

function terra.context:finish(anchor)
    local obj = table.remove(self.stack)
    if obj.lowlink == obj.compileindex then
        local scc = terra.newlist()
        local functions = terra.newlist()
        repeat
            local tocompile = table.remove(self.tobecompiled)
            scc:insert(tocompile)
            assert(tocompile.state == "typechecking")
            functions:insert(tocompile)
        until tocompile == obj
        
        if self.diagnostics:haserrors() then
            for i,o in ipairs(scc) do
                o.state = "error"
            end
            if typeerrordebugcallback then
                for i,o in ipairs(scc) do
                    typeerrordebugcallback(o)
                end
            end
        else
            for i,o in ipairs(scc) do
                o.state,o.scc = "typechecked",obj.compileindex
            end
            --dispatch callbacks that should occur once the function is typechecked
            for i,o in ipairs(scc) do
                if o.oncompletion then
                    for i,fn in ipairs(o.oncompletion) do
                        terra.invokeuserfunction(anchor,false,fn,o)
                    end    
                    o.oncompletion = nil
                end
            end
        end
    end
    self.diagnostics:finish()
end

function terra.context:oncompletion(obj,callback)
    obj.oncompletion = obj.oncompletion or terra.newlist()
    obj.oncompletion:insert(callback)
end

function terra.getcompilecontext()
    if not terra.globalcompilecontext then
        terra.globalcompilecontext = setmetatable({diagnostics = terra.newdiagnostics() , stack = {}, tobecompiled = {}, nextindex = 0},terra.context)
    end
    return terra.globalcompilecontext
end

-- END CONTEXT

-- ENVIRONMENT

terra.environment = {}
terra.environment.__index = terra.environment

function terra.environment:enterblock()
    local e = {}
    self._localenv = setmetatable(e,{ __index = self._localenv })
end
function terra.environment:leaveblock()
    self._localenv = getmetatable(self._localenv).__index
end
function terra.environment:localenv()
    return self._localenv
end
function terra.environment:luaenv()
    return self._luaenv
end
function terra.environment:combinedenv()
    return self._combinedenv
end

function terra.newenvironment(_luaenv)
    local self = setmetatable({},terra.environment)
    self._luaenv = _luaenv
    self._combinedenv = setmetatable({}, {
        __index = function(_,idx)
            return self._localenv[idx] or self._luaenv[idx]
        end;
        __newindex = function() 
            error("cannot define global variables or assign to upvalues in an escape")
        end;
    })
    self:enterblock()
    return self
end



-- END ENVIRONMENT


-- DIAGNOSTICS

terra.diagnostics = {}
terra.diagnostics.__index = terra.diagnostics

function terra.diagnostics:errorlist()
    return self._errors[#self._errors]
end

function terra.diagnostics:printsource(anchor)
    if not anchor.offset then 
        return
    end
    local filename = anchor.filename
    local filetext = self.filecache[filename] 
    if not filetext then
        local file = io.open(filename,"r")
        if file then
            filetext = file:read("*all")
            self.filecache[filename] = filetext
            file:close()
        end
    end
    if filetext then --if the code did not come from a file then we don't print the carrot, since we cannot (easily) find the text
        local begin,finish = anchor.offset + 1,anchor.offset + 1
        local TAB,NL = ("\t"):byte(),("\n"):byte()
        while begin > 1 and filetext:byte(begin) ~= NL do
            begin = begin - 1
        end
        if begin > 1 then
            begin = begin + 1
        end
        while finish < filetext:len() and filetext:byte(finish + 1) ~= NL do
            finish = finish + 1
        end
        local errlist = self:errorlist()
        local line = filetext:sub(begin,finish) 
        errlist:insert(line)
        errlist:insert("\n")
        for i = begin,anchor.offset do
            errlist:insert((filetext:byte(i) == TAB and "\t") or " ")
        end
        errlist:insert("^\n")
    end
end

function terra.diagnostics:clearfilecache()
    self.filecache = {}
end
terra.diagnostics.source = {}
function terra.diagnostics:reporterror(anchor,...)
    if not anchor or not anchor.filename or not anchor.linenumber then
        print(debug.traceback())
        print(terralib.printraw(anchor))
        error("nil anchor")
    end
    local errlist = self:errorlist()
    errlist:insert(anchor.filename..":"..anchor.linenumber..": ")
    local printedsource = false
    local function printsource()
        errlist:insert("\n")
        self:printsource(anchor)
        printedsource = true
    end
    for _,v in ipairs({...}) do
        if v == self.source then
            printsource()
        else
            errlist:insert(tostring(v))
        end
    end
    if not printedsource then
        printsource()
    end
end

function terra.diagnostics:haserrors()
    return #self._errors[#self._errors] > 0
end

function terra.diagnostics:begin()
    table.insert(self._errors,terra.newlist())
end

function terra.diagnostics:finish()
    local olderrors = table.remove(self._errors)
    local haderrors = #olderrors > 0
    if haderrors then
        self._errors[#self._errors]:insert(olderrors)
    end
    return haderrors
end

function terra.diagnostics:finishandabortiferrors(msg,depth)
    local errors = table.remove(self._errors)
    if #errors > 0 then
        local flatlist = {msg,"\n"}
        local function insert(l) 
            if type(l) == "table" then
                for i,e in ipairs(l) do
                    insert(e)
                end
            else
                table.insert(flatlist,l)
            end
        end
        insert(errors)
        self:clearfilecache()
        error(table.concat(flatlist),depth+1)
    end
end

function terra.newdiagnostics()
    return setmetatable({ filecache = {}, _errors = { terra.newlist() } },terra.diagnostics)
end

-- END DIAGNOSTICS

-- FUNCVARIANT

-- a function definition is an implementation of a function for a particular set of arguments
-- functions themselves are overloadable. Each potential implementation is its own function definition
-- with its own compile state, type, AST, etc.
 
terra.funcdefinition = {} --metatable for all function types
terra.funcdefinition.__index = terra.funcdefinition

function terra.funcdefinition:peektype() --look at the type but don't compile the function (if possible)
                                      --this will return success, <type if success == true>
    if self.type then
        return true,self.type
    end
    if not self.untypedtree.returntype then
        return false, terra.types.error
    end

    local params = self.untypedtree.parameters:map(function(entry) return entry.type end)
    local ret   = self.untypedtree.returntype
    self.type = terra.types.functype(params,ret,false) --for future calls
    
    return true, self.type
end

function terra.funcdefinition:gettype(cont,anchorduringcompilation)
    local ctx = terra.getcompilecontext()
    local apicall = not anchorduringcompilation -- this was called by the user, not the compiler
    local anchor = anchorduringcompilation or assert(self.untypedtree)
    local diag = ctx.diagnostics
    
    if apicall then diag:begin() end
    if "untyped" == self.state then
        ctx:begin(self)
        self:typecheckbody()
        ctx:finish(self.untypedtree or anchor)
        if not apicall then ctx:min(self.lowlink) end
    elseif "typechecking" == self.state then
        if not apicall then
            ctx:min(self.compileindex)
            local success, typ = self:peektype()
            if not success then
                diag:reporterror(anchor,"recursively called function needs an explicit return type.")
                diag:reporterror(self.untypedtree,"definition of recursively called function is here.")
            end
        elseif not cont then
            diag:reporterror(anchor,"attempting to compile a function that is already being compiled.")
        end
        if type(cont) == "function" then
            terra.getcompilecontext():oncompletion(self,cont) --register callback to fire when typechecking is done
            cont = nil
        end
    elseif "error" == self.state then
        if not diag:haserrors() then
            diag:reporterror(anchor,"referencing a function which failed to compile.")
            if not apicall then
                diag:reporterror(self.untypedtree,"definition of function which failed to compile.")
            end
        end
    end
    if apicall then diag:finishandabortiferrors("Errors reported during compilation.",2) end
    
    if type(cont) == "function" then
        cont(self)
    end
    
    return self.type or terra.types.error
end

local weakkeys = { __mode = "k" }
local function newweakkeytable()
    return setmetatable({},weakkeys)
end

local function cdatawithdestructor(ud,dest)
    local cd = ffi.cast("void*",ud)
    ffi.gc(cd,dest)
    return cd
end

terra.target = {}
terra.target.__index = terra.target
function terra.istarget(a) return getmetatable(a) == terra.target end
function terra.newtarget(tbl)
    if not type(tbl) == "table" then error("expected a table",2) end
    local Triple,CPU,Features,FloatABIHard = tbl.Triple,tbl.CPU,tbl.Features,tbl.FloatABIHard
    if Triple then
        CPU = CPU or ""
        Features = Features or ""
    end
    return setmetatable({ llvm_target = cdatawithdestructor(terra.inittarget(Triple,CPU,Features,FloatABIHard),terra.freetarget),
                          Triple = Triple,
                          cnametostruct = { general = {}, tagged = {}}  --map from llvm_name -> terra type used to make c structs unique per llvm_name
                        },terra.target)
end
function terra.target:getorcreatecstruct(displayname,tagged)
    local namespace
    if displayname ~= "" then
        namespace = tagged and self.cnametostruct.tagged or self.cnametostruct.general
    end
    local typ = namespace and namespace[displayname]
    if not typ then
        typ = terra.types.newstruct(displayname == "" and "anon" or displayname)
        typ.undefined = true
        if namespace then namespace[displayname] = typ end
    end
    return typ
end

local compilationunit = {}
compilationunit.__index = compilationunit
function terra.newcompilationunit(target,opt)
    assert(terra.istarget(target),"expected a target object")
    return setmetatable({ symbols = newweakkeytable(), 
                          livefunctions = opt and newweakkeytable() or nil,
                          llvm_cu = cdatawithdestructor(terra.initcompilationunit(target.llvm_target,opt),terra.freecompilationunit) },compilationunit) -- mapping from Types,Functions,Globals,Constants -> llvm value associated with them for this compilation
end
function compilationunit:addvalue(k,v)
    if type(k) ~= "string" then k,v = nil,k end
    local t = v:gettype()
    if terra.isglobalvar(v) then t:complete() end
    return terra.compilationunitaddvalue(self,k,v)
end
function compilationunit:jitvalue(v)
    local gv = self:addvalue(v)
    return terra.jit(self.llvm_cu,gv)
end
function compilationunit:free()
    assert(not self.livefunctions, "cannot explicitly release a compilation unit with auto-delete functions")
    ffi.gc(self.llvm_cu,nil) --unregister normal destructor object
    terra.freecompilationunit(self.llvm_cu)
end

terra.nativetarget = terra.newtarget {}
terra.jitcompilationunit = terra.newcompilationunit(terra.nativetarget,true) -- compilation unit used for JIT compilation, will eventually specify the native architecture

function terra.funcdefinition:jit(checknocont)
    assert(checknocont == nil, "compile no longer supports deferred action, use :gettype instead")
    if not self.rawjitptr then
        self.rawjitptr,self.stats.jit = terra.jitcompilationunit:jitvalue(self)
    end
    return self.rawjitptr
end
terra.funcdefinition.compile = terra.funcdefinition.jit

function terra.funcdefinition:__call(...)
    local ffiwrapper = self:getpointer()
    return ffiwrapper(...)
end
function terra.funcdefinition:getpointer()
    if not self.ffiwrapper then
        local rawptr = self:jit()
        self.ffiwrapper = ffi.cast(terra.types.pointer(self.type):cstring(),rawptr)
    end
    return self.ffiwrapper
end

function terra.funcdefinition:setinlined(v)
    if self.state ~= "untyped" then
        error("inlining state can only be changed before typechecking",2)
    end
    self.alwaysinline = v
end

function terra.funcdefinition:disas()
    print("definition ", self:gettype())
    terra.disassemble(terra.jitcompilationunit:addvalue(self),self:jit())
end
function terra.funcdefinition:printstats()
    print("definition ", self:gettype())
    for k,v in pairs(self.stats) do
        print("",k,v)
    end
end

terra.llvm_gcdebugmetatable = { __gc = function(obj)
    print("GC IS CALLED")
end }

function terra.isfunctiondefinition(obj)
    return getmetatable(obj) == terra.funcdefinition
end

--END FUNCDEFINITION

-- FUNCTION
-- a function is a list of possible function definitions that can be invoked
-- it is implemented this way to support function overloading, where the same symbol
-- may have different definitions

terra.func = {} --metatable for all function types
terra.func.__index = function(self,idx)
    local r = terra.func[idx]
    if r then return r end
    return function(self,...)
        local ND = #self.definitions
        if ND == 1 then --faster path, avoid creating a table of arguments
            local dfn = self.definitions[1]
            return dfn[idx](dfn,...)
        elseif ND == 0 then
            error("attempting to call "..idx.." on undefined function",2)
        end
        local results
        for i,dfn in ipairs(self.definitions) do
            local r = { dfn[idx](dfn,...) }
            results = results or r
        end
        return unpack(results)
    end
end

function terra.func:__call(...)
    if rawget(self,"fastcall") then
        return self.fastcall(...)
    end
    if #self.definitions == 1 then --generate fast path for the non-overloaded case
        local defn = self.definitions[1]
        local ptr = defn:getpointer() --forces compilation
        self.fastcall = ptr
        return self.fastcall(...)
    end
    
    local results
    for i,v in ipairs(self.definitions) do
        --TODO: this is very inefficient, we should have a routine which
        --figures out which function to call based on argument types
        results = {pcall(v.__call,v,...)}
        if results[1] == true then
            table.remove(results,1)
            return unpack(results)
        end
    end
    --none of the definitions worked, remove the final error
    error(results[2])
end

function terra.func:adddefinition(v)
    v.name = self.name --propagate function name to definition 
                       --this will be used as the name for llvm debugging, etc.
    self.fastcall = nil
    self.definitions:insert(v)
end

function terra.func:getdefinitions()
    return self.definitions
end
function terra.func:getname() return self.name end
function terra.func:setname(name)
    self.name = tostring(name)
    for i,d in ipairs(self.definitions) do
        d.name = self.name
    end
    return self
end

function terra.isfunction(obj)
    return getmetatable(obj) == terra.func
end

-- END FUNCTION

-- GLOBALVAR

terra.globalvar = {} --metatable for all global variables
terra.globalvar.__index = terra.globalvar

function terra.isglobalvar(obj)
    return getmetatable(obj) == terra.globalvar
end

function terra.globalvar:gettype()
    return self.type
end

--terra.createglobal provided by tcompiler.cpp
function terra.global(typ,c, name, isextern, addressspace)
    if not terra.types.istype(typ) then
        c,name,isextern,addressspace = typ,c,name,isextern --shift arguments right
        c = terra.constant(c)
        typ = c.type
    elseif c ~= nil then
        c = terra.constant(typ,c)
    end
    
    local gbl =  setmetatable({type = typ, isglobal = true, symbol = terra.newsymbol(name or "<global>"), initializer = c, name = name, isextern = isextern or false, addressspace = tonumber(addressspace) or 0},terra.globalvar)
    
    if c then --if we have an initializer we know that the type is not opaque and we can create the variable
              --we need to call this now because it is possible for the initializer's underlying cdata object to change value
              --in later code
        gbl:getpointer()
    end

    return gbl
end

function terra.globalvar:getpointer()
    if not self.cdata_ptr then
        local rawptr = terra.jitcompilationunit:jitvalue(self)
        self.cdata_ptr = terra.cast(terra.types.pointer(self.type),rawptr)
    end
    return self.cdata_ptr
end
function terra.globalvar:get()
    local ptr = self:getpointer()
    return ptr[0]
end
function terra.globalvar:set(v)
    local ptr = self:getpointer()
    ptr[0] = v
end
    

-- END GLOBALVAR

-- MACRO

terra.macro = {}
terra.macro.__index = terra.macro
terra.macro.__call = function(self,...)
    if not self.fromlua then
        error("macros must be called from inside terra code",2)
    end
    return self.fromlua(...)
end
function terra.macro:run(ctx,tree,...)
    if self._internal then
        return self.fromterra(ctx,tree,...)
    else
        return self.fromterra(...)
    end
end
function terra.ismacro(t)
    return getmetatable(t) == terra.macro
end

function terra.createmacro(fromterra,fromlua)
    return setmetatable({fromterra = fromterra,fromlua = fromlua}, terra.macro)
end
function terra.internalmacro(...) 
    local m = terra.createmacro(...)
    m._internal = true
    return m
end

_G["macro"] = terra.createmacro --introduce macro intrinsic into global namespace

-- END MACRO


function terra.israwlist(l)
    if terra.islist(l) then
        return true
    elseif type(l) == "table" and not getmetatable(l) then
        local sz = #l
        local i = 0
        for k,v in pairs(l) do
            i = i + 1
        end
        return i == sz --table only has integer keys and no other keys, we treat it as a list
    end
    return false
end

-- QUOTE
terra.quote = {}
terra.quote.__index = terra.quote
function terra.isquote(t)
    return getmetatable(t) == terra.quote
end

function terra.quote:astype()
    if not self.tree:is "typedexpression" or not self.tree.expression:is "luaobject" or not terra.types.istype(self.tree.expression.value) then
        error("quoted value is not a type")
    end
    return self.tree.expression.value
end
function terra.quote:istyped()
    return self.tree:is "typedexpression" and not self.tree.expression:is "luaobject"
end
function terra.quote:gettype()
    if not self:istyped() then
        error("not a typed quote")
    end
    return self.tree.expression.type
end
function terra.quote:islvalue()
    if not self:istyped() then
        error("not a typed quote")
    end
    return self.tree.expression.lvalue
end
function terra.quote:asvalue()
    local function getvalue(e)
        if e:is "literal" then
            if type(e.value) == "userdata" then
                return tonumber(ffi.cast("uint64_t *",e.value)[0])
            else
                return e.value
            end
        elseif e:is "constant" then
            return tonumber(e.value.object) or e.value.object
        elseif e:is "constructor" then
            local t,typ = {},e.type
            for i,r in ipairs(typ:getentries()) do
                local v,e = getvalue(e.expressions[i]) 
                if e then return nil,e end
                local key = typ.convertible == "tuple" and i or r.field
                t[key] = v
            end
            return t
        elseif e:is "typedexpression" then
            return getvalue(e.expression)
        elseif e:is "operator" and e.operator == tokens["-"] and #e.operands == 1 then
            local v,er = getvalue(e.operands[1])
            return type(v) == "number" and -v, er
        elseif e:is "var" and terra.issymbol(e.symbol) then
            return e.symbol
        else
            return nil, "not a constant value (note: :asvalue() isn't implement for all constants yet)"
        end
    end
    return getvalue(self.tree)
end
function terra.newquote(tree)
    return setmetatable({ tree = tree }, terra.quote)
end

-- END QUOTE

-- SYMBOL
terra.symbol = {}
terra.symbol.__index = terra.symbol
function terra.issymbol(s)
    return getmetatable(s) == terra.symbol
end
terra.symbol.count = 0

function terra.newsymbol(typ,displayname)
    if typ and not terra.types.istype(typ) then
        if type(typ) == "string" and displayname == nil then
            displayname = typ
            typ = nil
        else
            error("argument is not a type",2)
        end
    end
    assert(not displayname or type(displayname) == "string")
    local self = setmetatable({
        id = terra.symbol.count,
        type = typ,
        displayname = displayname
    },terra.symbol)
    terra.symbol.count = terra.symbol.count + 1
    return self
end

function terra.symbol:__tostring()
    return "$"..(self.displayname or tostring(self.id))
end
function terra.symbol:tocname() return "__symbol"..tostring(self.id) end

_G["symbol"] = terra.newsymbol 

-- INTRINSIC

function terra.intrinsic(str, typ)
    local typefn
    if typ == nil and type(str) == "function" then
        typefn = str
    elseif type(str) == "string" and terra.types.istype(typ) then
        typefn = function() return str,typ end
    else
        error("expected a name and type or a function providing a name and type but found "..tostring(str) .. ", " .. tostring(typ))
    end
    local function intrinsiccall(diag,e,...)
        local args = terra.newlist {...}
        local types = args:map("gettype")
        local name,intrinsictype = typefn(types)
        if type(name) ~= "string" then
            diag:reporterror(e,"expected an intrinsic name but found ",terra.type(name))
            name = "<unknownintrinsic>"
        elseif intrinsictype == terra.types.error then
            diag:reporterror(e,"intrinsic ",name," does not support arguments: ",unpack(types))
            intrinsictype = terra.types.funcpointer(types,{})
        elseif not terra.types.istype(intrinsictype) or not intrinsictype:ispointertofunction() then
            diag:reporterror(e,"expected intrinsic to resolve to a function type but found ",terra.type(intrinsictype))
            intrinsictype = terra.types.funcpointer(types,{})
        end
        local fn = terralib.externfunction(name,intrinsictype,e)
        local literal = terra.createterraexpression(diag,e,fn)
        local rawargs = args:map("tree")
        return newobject(e,T.apply,literal,rawargs)
    end
    return terra.internalmacro(intrinsiccall)
end

terra.asm = terra.internalmacro(function(diag,tree,returntype, asm, constraints,volatile,...)
    local args = terra.newlist({...}):map(function(e) return e.tree end)
    return newobject(tree, T.inlineasm,returntype:astype(), tostring(asm:asvalue()), not not volatile:asvalue(), tostring(constraints:asvalue()), args)
end)
    

-- CONSTRUCTORS
do  --constructor functions for terra functions and variables
    local name_count = 0
    local function newfunctiondefinition(newtree,env,reciever)
        local obj = { untypedtree = newtree, filename = newtree.filename, state = "untyped", stats = {} }
        local fn = setmetatable(obj,terra.funcdefinition)
        
        --handle desugaring of methods defintions by adding an implicit self argument
        if reciever ~= nil then
            local pointerto = terra.types.pointer
            local addressof = newobject(newtree,T.luaexpression,function() return pointerto(reciever) end,true)
            local sym = newobject(newtree,T.namedident,"self")
            local implicitparam = newobject(newtree,T.unevaluatedparam,sym,addressof)
            --add the implicit parameter to the parameter list
            local newparameters = List{implicitparam}
            newparameters:insertall(newtree.parameters)
            fn.untypedtree = copyobject(newtree,{ parameters = newparameters})
        end
        local starttime = terra.currenttimeinseconds() 
        fn.untypedtree = terra.specialize(fn.untypedtree,env,3)
        fn.stats.specialize = terra.currenttimeinseconds() - starttime
        return fn
    end
    
    local function mkfunction(name)
        assert(name and type(name) == "string")
        return setmetatable({definitions = terra.newlist(), name = name},terra.func)
    end
    
    local function layoutstruct(st,tree,env)
        local diag = terra.newdiagnostics()
        diag:begin()
        if st.tree then
            diag:reporterror(tree,"attempting to redefine struct")
            diag:reporterror(st.tree,"previous definition was here")
        end
        st.undefined = nil

        local function getstructentry(v) assert(v.kind == "structentry")
            local success,resolvedtype = terra.evalluaexpression(diag,env,v.type)
            if not success then return end
            if not terra.types.istype(resolvedtype) then
                diag:reporterror(v,"lua expression is not a terra type but ", terra.type(resolvedtype))
                return terra.types.error
            end
            return { field = v.key, type = resolvedtype }
        end
        
        local function getrecords(records)
            return records:map(function(v)
                if v.kind == "structlist" then
                    return getrecords(v.entries)
                else
                    return getstructentry(v)
                end
            end)
        end
        local success,metatype 
        if tree.metatype then
            success,metatype = terra.evalluaexpression(diag,env,tree.metatype)
        end
        st.entries = getrecords(tree.records.entries)
        st.tree = tree --to track whether the struct has already beend defined
                       --we keep the tree to improve error reporting
        st.anchor = tree --replace the anchor generated by newstruct with this struct definition
                         --this will cause errors on the type to be reported at the definition
        if success then
            local success,err = pcall(metatype,st)
            if not success then
                diag:reporterror(tree,"Error evaluating metatype function: "..err)
            end
        end
        diag:finishandabortiferrors("Errors reported during struct definition.",3)
    end

    function terra.declarefunctions(N,...)
        return declareobjects(N,function(origv,name)
            return (terra.isfunction(origv) and origv) or mkfunction(name)
        end,...)
    end

    function terra.defineobjects(fmt,envfn,...)
        local cmds = terralib.newlist()
        local nargs = 2
        for i = 1, #fmt do --collect declaration/definition commands
            local c = fmt:sub(i,i)
            local name,tree = select(nargs*(i-1) + 1,...)
            cmds:insert { c = c, name = name, tree = tree }
        end
        local env = setmetatable({},{__index = envfn()})
        local function paccess(name,d,t,k,v)
            local s,r = pcall(function()
                if v then t[k] = v
                else return t[k] end
            end)
            if not s then
                error("failed attempting to index field '"..k.."' in name '"..name.."' (expected a table but found "..terra.type(t)..")" ,d)
            end
            return r
        end
        local function enclosing(name)
            local t = env
            for m in name:gmatch("([^.]*)%.") do
                t = paccess(name,4,t,m) --TODO, guard the failure here
            end
            return t,name:match("[^.]*$")
        end
        
        local decls = terralib.newlist()
        for i,c in ipairs(cmds) do --pass 1 declare all structs
            if "s" == c.c then
                local tbl,lastname = enclosing(c.name)
                local v = paccess(c.name,3,tbl,lastname)
                if not terra.types.istype(v) or not v:isstruct() then
                    v = terra.types.newstruct(c.name,1)
                    v.undefined = true
                end
                decls[i] = v
                paccess(c.name,3,tbl,lastname,v)
            end
        end
        local r = terralib.newlist()
        for i,c in ipairs(cmds) do -- pass 2 declare all functions, create return list
            local tbl,lastname = enclosing(c.name)
            if "s" ~= c.c then
                if "m" == c.c then
                    if not terra.types.istype(tbl) or not tbl:isstruct() then
                        error("expected a struct but found "..terra.type(tbl).. " when attempting to add method "..c.name,2)
                    end
                    tbl = tbl.methods
                end
                local v = paccess(c.name,3,tbl,lastname)
                v = terra.isfunction(v) and v or mkfunction(c.name)
                decls[i] = v
                paccess(c.name,3,tbl,lastname,v)
            end
            if lastname == c.name then
                r:insert(decls[i])
            end
        end    
        for i,c in ipairs(cmds) do -- pass 3 define functions
            if c.tree then
                if "s" == c.c then
                    layoutstruct(decls[i],c.tree,env)
                elseif "m" == c.c then
                    local reciever = enclosing(c.name)
                    decls[i]:adddefinition(newfunctiondefinition(c.tree,env,reciever))
                else assert("f" == c.c)
                    decls[i]:adddefinition(newfunctiondefinition(c.tree,env))
                end
            end
        end
        return unpack(r)
    end

    function terra.anonstruct(tree,envfn)
        local st = terra.types.newstruct("anon",2)
        layoutstruct(st,tree,envfn())
        return st
    end

    function terra.anonfunction(tree,envfn)
        local fn = mkfunction("anon ("..tree.filename..":"..tree.linenumber..")")
        fn:adddefinition(newfunctiondefinition(tree,envfn(),nil))
        return fn
    end

    function terra.externfunction(name,typ,anchor)
        anchor = anchor or terra.newanchor(1)
        typ = typ:ispointertofunction() and typ.type or typ
        local obj = { type = typ, state = "untyped", isextern = true, untypedtree = anchor, stats = {} }
        setmetatable(obj,terra.funcdefinition)
        
        local fn = mkfunction(name)
        fn:adddefinition(obj)
        
        return fn
    end

    function terra.definequote(tree,envfn)
        return terra.newquote(terra.specialize(tree,envfn(),2))
    end
end

-- END CONSTRUCTORS

-- TYPE

do 

    --some utility functions used to generate unique types and names
    
    --returns a function string -> string that makes names unique by appending numbers
    local function uniquenameset(sep)
        local cache = {}
        local function get(name)
            local count = cache[name]
            if not count then
                cache[name] = 1
                return name
            end
            local rename = name .. sep .. tostring(count)
            cache[name] = count + 1
            return get(rename) -- the string name<sep><count> might itself be a type name already
        end
        return get
    end
    --sanitize a string, making it a valid lua/C identifier
    local function tovalididentifier(name)
        return tostring(name):gsub("[^_%w]","_"):gsub("^(%d)","_%1"):gsub("^$","_") --sanitize input to be valid identifier
    end
    
    local function memoizefunction(fn)
        local info = debug.getinfo(fn,'u')
        local nparams = not info.isvararg and info.nparams
        local cachekey = {}
        local values = {}
        local nilkey = {} --key to use in place of nil when a nil value is seen
        return function(...)
            local key = cachekey
            for i = 1,nparams or select('#',...) do
                local e = select(i,...)
                if e == nil then e = nilkey end
                local n = key[e]
                if not n then
                    n = {}; key[e] = n
                end
                key = n
            end
            local v = values[key]
            if not v then
                v = fn(...); values[key] = v
            end
            return v
        end
    end
    
    local types = {}
    local defaultproperties = { "name", "tree", "undefined", "incomplete", "convertible", "cachedcstring", "llvm_definingfunction" }
    for i,dp in ipairs(defaultproperties) do
        T.Type[dp] = false
    end
    T.Type.__index = nil -- force overrides
    function T.Type:__index(key)
        local N = tonumber(key)
        if N then
            return T.array(self,N) -- int[3] should create an array
        else
            return getmetatable(self)[key]
        end
    end
    T.Type.__tostring = nil --force override to occur
    T.Type.__tostring = memoizefunction(function(self)
        if self:isstruct() then 
            if self.metamethods.__typename then
                local status,r = pcall(function() 
                    return tostring(self.metamethods.__typename(self))
                end)
                if status then return r end
            end
            return self.name
        elseif self:ispointer() then return "&"..tostring(self.type)
        elseif self:isvector() then return "vector("..tostring(self.type)..","..tostring(self.N)..")"
        elseif self:isfunction() then return mkstring(self.parameters,"{",",",self.isvararg and " ...}" or "}").." -> "..tostring(self.returntype)
        elseif self:isarray() then
            local t = tostring(self.type)
            if self.type:ispointer() then
                t = "("..t..")"
            end
            return t.."["..tostring(self.N).."]"
        end
        if not self.name then error("unknown type?") end
        return self.name
    end)
    
    T.Type.printraw = terra.printraw
    function T.Type:isprimitive() return self.kind == "primitive" end
    function T.Type:isintegral() return self.kind == "primitive" and self.type == "integer" end
    function T.Type:isfloat() return self.kind == "primitive" and self.type == "float" end
    function T.Type:isarithmetic() return self.kind == "primitive" and (self.type == "integer" or self.type == "float") end
    function T.Type:islogical() return self.kind == "primitive" and self.type == "logical" end
    function T.Type:canbeord() return self:isintegral() or self:islogical() end
    function T.Type:ispointer() return self.kind == "pointer" end
    function T.Type:isarray() return self.kind == "array" end
    function T.Type:isfunction() return self.kind == "functype" end
    function T.Type:isstruct() return self.kind == "struct" end
    function T.Type:ispointertostruct() return self:ispointer() and self.type:isstruct() end
    function T.Type:ispointertofunction() return self:ispointer() and self.type:isfunction() end
    function T.Type:isaggregate() return self:isstruct() or self:isarray() end
    
    function T.Type:iscomplete() return not self.incomplete end
    
    function T.Type:isvector() return self.kind == "vector" end
    
    function T.Type:isunit() return types.unit == self end
    
    local applies_to_vectors = {"isprimitive","isintegral","isarithmetic","islogical", "canbeord"}
    for i,n in ipairs(applies_to_vectors) do
        T.Type[n.."orvector"] = function(self)
            return self[n](self) or (self:isvector() and self.type[n](self.type))  
        end
    end
    
    --pretty print of layout of type
    function T.Type:printpretty()
        local seen = {}
        local function print(self,d)
            local function indent(l)
                io.write("\n")
                for i = 1,d+1+(l or 0) do 
                    io.write("  ")
                end
            end
            io.write(tostring(self))
            if seen[self] then return end
            seen[self] = true
            if self:isstruct() then
                io.write(":")
                local layout = self:getlayout()
                for i,e in ipairs(layout.entries) do
                    indent()
                    io.write(tostring(e.key)..": ")
                    print(e.type,d+1)
                end
            elseif self:isarray() or self:ispointer() then
                io.write(" ->")
                indent()
                print(self.type,d+1)
            elseif self:isfunction() then
                io.write(": ")
                indent() io.write("parameters: ")
                print(types.tuple(unpack(self.parameters)),d+1)
                indent() io.write("returntype:")
                print(self.returntype,d+1)
            end
        end
        print(self,0)
        io.write("\n")
    end
    local function memoizeproperty(data)
        local name = data.name
        local defaultvalue = data.defaultvalue
        local erroronrecursion = data.erroronrecursion
        local getvalue = data.getvalue

        local errorresult = { "<errorresult>" }
        local key = "cached"..name
        local inside = "inget"..name
        T.struct[key],T.struct[inside] = false,false
        return function(self,anchor)
            if not self[key] then
                local diag = terra.getcompilecontext().diagnostics
                local haderrors = diag:haserrors()
                diag:begin()
                if self[inside] then
                    diag:reporterror(self.anchor,erroronrecursion)
                else 
                    self[inside] = true
                    self[key] = getvalue(self,diag,anchor or terra.newanchor(1))
                    self[inside] = nil
                end
                if diag:haserrors() then
                    self[key] = errorresult
                end
                if anchor then
                    diag:finish() 
                else
                    diag:finishandabortiferrors("Errors reported during struct property lookup.",2)
                end

            end
            if self[key] == errorresult then
                local msg = "Attempting to get a property of a type that previously resulted in an error."
                if anchor then
                    local diag = terra.getcompilecontext().diagnostics
                    if not diag:haserrors() then
                        diag:reporterror(self.anchor,msg)
                    end
                    return defaultvalue
                else
                    error(msg,2)
                end
            end
            return self[key]
        end
    end

    local function definecstruct(nm,layout)
        local str = "struct "..nm.." { "
        local entries = layout.entries
        for i,v in ipairs(entries) do
        
            local prevalloc = entries[i-1] and entries[i-1].allocation
            local nextalloc = entries[i+1] and entries[i+1].allocation
    
            if v.inunion and prevalloc ~= v.allocation then
                str = str .. " union { "
            end
            
            local keystr = terra.issymbol(v.key) and v.key:tocname() or v.key
            str = str..v.type:cstring().." "..keystr.."; "
            
            if v.inunion and nextalloc ~= v.allocation then
                str = str .. " }; "
            end
            
        end
        str = str .. "};"
        ffi.cdef(str)
    end
    local uniquetypenameset = uniquenameset("_")
    local function uniquecname(name) --used to generate unique typedefs for C
        return uniquetypenameset(tovalididentifier(name))
    end
    function T.Type:cstring()
        if not self.cachedcstring then
            --assumption: cstring needs to be an identifier, it cannot be a derived type (e.g. int*)
            --this makes it possible to predict the syntax of subsequent typedef operations
            if self:isintegral() then
                self.cachedcstring = tostring(self).."_t"
            elseif self:isfloat() then
                self.cachedcstring = tostring(self)
            elseif self:ispointer() and self.type:isfunction() then --function pointers and functions have the same typedef
                local ftype = self.type
                local rt = (ftype.returntype:isunit() and "void") or ftype.returntype:cstring()
                local function getcstring(t)
                    if t == types.rawstring then
                        --hack to make it possible to pass strings to terra functions
                        --this breaks some lesser used functionality (e.g. passing and mutating &int8 pointers)
                        --so it should be removed when we have a better solution
                        return "const char *"
                    else
                        return t:cstring()
                    end
                end
                local pa = ftype.parameters:map(getcstring)
                if not self.cachedcstring then
                    pa = mkstring(pa,"(",",","")
                    if ftype.isvararg then
                        pa = pa .. ",...)"
                    else
                        pa = pa .. ")"
                    end
                    local ntyp = uniquecname("function")
                    local cdef = "typedef "..rt.." (*"..ntyp..")"..pa..";"
                    ffi.cdef(cdef)
                    self.cachedcstring = ntyp
                end
            elseif self:isfunction() then
                error("asking for the cstring for a function?",2)
            elseif self:ispointer() then
                local value = self.type:cstring()
                if not self.cachedcstring then
                    local nm = uniquecname("ptr_"..value)
                    ffi.cdef("typedef "..value.."* "..nm..";")
                    self.cachedcstring = nm
                end
            elseif self:islogical() then
                self.cachedcstring = "bool"
            elseif self:isstruct() then
                local nm = uniquecname(tostring(self))
                ffi.cdef("typedef struct "..nm.." "..nm..";") --just make a typedef to the opaque type
                                                              --when the struct is 
                self.cachedcstring = nm
                if self.cachedlayout then
                    definecstruct(nm,self.cachedlayout)
                end
            elseif self:isarray() then
                local value = self.type:cstring()
                if not self.cachedcstring then
                    local nm = uniquecname(value.."_arr")
                    ffi.cdef("typedef "..value.." "..nm.."["..tostring(self.N).."];")
                    self.cachedcstring = nm
                end
            elseif self:isvector() then
                local value = self.type:cstring()
                local elemSz = ffi.sizeof(value)
                local nm = uniquecname(value.."_vec")
                local pow2 = 1 --round N to next power of 2
                while pow2 < self.N do pow2 = 2*pow2 end
                ffi.cdef("typedef "..value.." "..nm.." __attribute__ ((vector_size("..tostring(pow2*elemSz)..")));")
                self.cachedcstring = nm 
            elseif self == types.niltype then
                local nilname = uniquecname("niltype")
                ffi.cdef("typedef void * "..nilname..";")
                self.cachedcstring = nilname
            elseif self == types.opaque then
                self.cachedcstring = "void"
            elseif self == types.error then
                self.cachedcstring = "int"
            else
                error("NYI - cstring")
            end
            if not self.cachedcstring then error("cstring not set? "..tostring(self)) end
            
            --create a map from this ctype to the terra type to that we can implement terra.typeof(cdata)
            local ctype = ffi.typeof(self.cachedcstring)
            types.ctypetoterra[tonumber(ctype)] = self
            local rctype = ffi.typeof(self.cachedcstring.."&")
            types.ctypetoterra[tonumber(rctype)] = self
            
            if self:isstruct() then
                local function index(obj,idx)
                    local method = self:getmethod(idx)
                    if terra.ismacro(method) then
                        error("calling a terra macro directly from Lua is not supported",2)
                    end
                    return method
                end
                ffi.metatype(ctype, self.metamethods.__luametatable or { __index = index })
            end
        end
        return self.cachedcstring
    end

    

    T.struct.getentries = memoizeproperty{
        name = "entries";
        defaultvalue = terra.newlist();
        erroronrecursion = "recursively calling getentries on type";
        getvalue = function(self,diag,anchor)
            if not self:isstruct() then
                error("attempting to get entries of non-struct type: ", tostring(self))
            end
            local entries = self.entries
            if type(self.metamethods.__getentries) == "function" then
                local success,result = terra.invokeuserfunction(self.anchor,false,self.metamethods.__getentries,self)
                entries = (success and result) or {}
            elseif self.undefined then
                diag:reporterror(anchor,"attempting to use a type before it is defined")
                diag:reporterror(self.anchor,"type was declared here.")
            end
            if type(entries) ~= "table" then
                diag:reporterror(self.anchor,"computed entries are not a table")
                return
            end
            local function checkentry(e,results)
                if type(e) == "table" then
                    local f = e.field or e[1] 
                    local t = e.type or e[2]
                    if terra.types.istype(t) and (type(f) == "string" or terra.issymbol(f)) then
                        results:insert { type = t, field = f}
                        return
                    elseif terra.israwlist(e) then
                        local union = terra.newlist()
                        for i,se in ipairs(e) do checkentry(se,union) end
                        results:insert(union)
                        return
                    end
                end
                diag:reporterror(self.anchor,"expected either a field type pair (e.g. { field = <string>, type = <type> } or {<string>,<type>} ), or a list of valid entries representing a union")
            end
            local checkedentries = terra.newlist()
            for i,e in ipairs(entries) do checkentry(e,checkedentries) end
            return checkedentries
        end
    }
    local function reportopaque(anchor)
        local msg = "attempting to use an opaque type where the layout of the type is needed"
        if anchor then
            local diag = terra.getcompilecontext().diagnostics
            if not diag:haserrors() then
                terra.getcompilecontext().diagnostics:reporterror(anchor,msg)
            end
        else
            error(msg,4)
        end
    end
    T.struct.getlayout = memoizeproperty {
        name = "layout"; 
        defaultvalue = { entries = terra.newlist(), keytoindex = {}, invalid = true };
        erroronrecursion = "type recursively contains itself";
        getvalue = function(self,diag,anchor)
            local tree = self.anchor
            local entries = self:getentries(anchor)
            local nextallocation = 0
            local uniondepth = 0
            local unionsize = 0
            
            local layout = {
                entries = terra.newlist(),
                keytoindex = {}
            }
            local function addentry(k,t)
                local function ensurelayout(t)
                    if t:isstruct() then
                        t:getlayout(anchor)
                    elseif t:isarray() then
                        ensurelayout(t.type)
                    elseif t == types.opaque then
                        reportopaque(tree)    
                    end
                end
                ensurelayout(t)
                local entry = { type = t, key = k, allocation = nextallocation, inunion = uniondepth > 0 }
                
                if layout.keytoindex[entry.key] ~= nil then
                    diag:reporterror(tree,"duplicate field ",tostring(entry.key))
                end

                layout.keytoindex[entry.key] = #layout.entries
                layout.entries:insert(entry)
                if uniondepth > 0 then
                    unionsize = unionsize + 1
                else
                    nextallocation = nextallocation + 1
                end
            end
            local function beginunion()
                uniondepth = uniondepth + 1
            end
            local function endunion()
                uniondepth = uniondepth - 1
                if uniondepth == 0 and unionsize > 0 then
                    nextallocation = nextallocation + 1
                    unionsize = 0
                end
            end
            local function addentrylist(entries)
                for i,e in ipairs(entries) do
                    if terra.islist(e) then
                        beginunion()
                        addentrylist(e)
                        endunion()
                    else
                        addentry(e.field,e.type)
                    end
                end
            end
            addentrylist(entries)
            
            dbprint(2,"Resolved Named Struct To:")
            dbprintraw(2,self)
            if not diag:haserrors() and self.cachedcstring then
                definecstruct(self.cachedcstring,layout)
            end
            return layout
        end;
    }
    function T.functype:completefunction(anchor)
        for i,p in ipairs(self.parameters) do p:complete(anchor) end
        self.returntype:complete(anchor)
        return self
    end
    function T.Type:complete(anchor) 
        if self.incomplete then
            if self:isarray() then
                self.type:complete(anchor)
                self.incomplete = self.type.incomplete
            elseif self == types.opaque or self:isfunction() then
                reportopaque(anchor)
            else
                assert(self:isstruct())
                local layout = self:getlayout(anchor)
                if not layout.invalid then
                    self.incomplete = nil --static initializers run only once
                                          --if one of the members of this struct recursively
                                          --calls complete on this type, then it will return before the static initializer has run
                    for i,e in ipairs(layout.entries) do
                        e.type:complete(anchor)
                    end
                    if type(self.metamethods.__staticinitialize) == "function" then
                        terra.invokeuserfunction(self.anchor,false,self.metamethods.__staticinitialize,self)
                    end
                end
            end
        end
        return self
    end
    
    local function defaultgetmethod(self,methodname)
        local fnlike = self.methods[methodname]
        if not fnlike and terra.ismacro(self.metamethods.__methodmissing) then
            fnlike = terra.internalmacro(function(ctx,tree,...)
                return self.metamethods.__methodmissing:run(ctx,tree,methodname,...)
            end)
        end
        return fnlike
    end
    function T.struct:getmethod(methodname)
        local gm = (type(self.metamethods.__getmethod) == "function" and self.metamethods.__getmethod) or defaultgetmethod
        local success,result = pcall(gm,self,methodname)
        if not success then
            return nil,"error while looking up method: "..result
        elseif result == nil then
            return nil, "no such method "..tostring(methodname).." defined for type "..tostring(self)
        else
            return result
        end
    end
    function T.struct:getfield(fieldname)
        local l = self:getlayout()
        local i = l.keytoindex[fieldname]
        if not i then return nil, ("field name '%s' is not a raw field of type %s"):format(tostring(self),tostring(fieldname)) end
        return l.entries[i+1]
    end
    function T.struct:getfields()
        return self:getlayout().entries
    end
        
    function types.istype(t)
        return T.Type:isclassof(t)
    end
    
    --map from luajit ffi ctype objects to corresponding terra type
    types.ctypetoterra = {}
    
    local function globaltype(name, typ)
        typ.name = typ.name or name
        rawset(_G,name,typ)
        types[name] = typ
    end
    
    --initialize integral types
    local integer_sizes = {1,2,4,8}
    for _,size in ipairs(integer_sizes) do
        for _,s in ipairs{true,false} do
            local name = "int"..tostring(size * 8)
            if not s then
                name = "u"..name
            end
            local typ = T.primitive("integer",size,s)
            globaltype(name,typ)
            typ:cstring() -- force registration of integral types so calls like terra.typeof(1LL) work
        end
    end  
    
    globaltype("float", T.primitive("float",4,true))
    globaltype("double",T.primitive("float",8,true))
    globaltype("bool", T.primitive("logical",1,false))
    
    types.error,T.error.name = T.error,"<error>"
    
    types.niltype = T.niltype
    globaltype("niltype",T.niltype)
    
    types.opaque,T.opaque.incomplete = T.opaque,true
    globaltype("opaque", T.opaque)
    
    types.array,types.vector,types.functype = T.array,T.vector,T.functype
    
    T.functype.incomplete = true
    function types.pointer(t,as) return T.pointer(t,as or 0) end
    function T.array:init()
        self.incomplete = true
    end
    
    function T.vector:init()
        if not self.type:isprimitive() and self.type ~= T.error then
            error("vectors must be composed of primitive types (for now...) but found type "..tostring(self.type))
        end
    end
    
    types.tuple = memoizefunction(function(...)
        local args = terra.newlist {...}
        local t = types.newstruct()
        for i,e in ipairs(args) do
            if not types.istype(e) then 
                error("expected a type but found "..type(e))
            end
            t.entries:insert {"_"..(i-1),e}
        end
        t.metamethods.__typename = function(self)
            return mkstring(args,"{",",","}")
        end
        t:setconvertible("tuple")
        return t
    end)
    local getuniquestructname = uniquenameset("$")
    function types.newstruct(displayname,depth)
        displayname = displayname or "anon"
        depth = depth or 1
        return types.newstructwithanchor(displayname,terra.newanchor(1 + depth))
    end
    function T.struct:setconvertible(b)
        assert(self.incomplete)
        self.convertible = b
    end
    function types.newstructwithanchor(displayname,anchor)
        assert(displayname ~= "")
        local name = getuniquestructname(displayname)
        local tbl = T.struct(name) 
        tbl.entries = List()
        tbl.methods = {}
        tbl.metamethods = {}
        tbl.anchor = anchor
        tbl.incomplete = true
        return tbl
    end
   
    function types.funcpointer(parameters,ret,isvararg)
        if types.istype(parameters) then
            parameters = {parameters}
        end
        if not types.istype(ret) and terra.israwlist(ret) then
            ret = #ret == 1 and ret[1] or types.tuple(unpack(ret))
        end
        return types.pointer(types.functype(List{unpack(parameters)},ret,not not isvararg))
    end
    types.unit = types.tuple()
    globaltype("int",types.int32)
    globaltype("uint",types.uint32)
    globaltype("long",types.int64)
    globaltype("intptr",types.uint64)
    globaltype("ptrdiff",types.int64)
    globaltype("rawstring",types.pointer(types.int8))
    terra.types = types
    terra.memoize = memoizefunction
end

function T.tree:setlvalue(v)
    if v then
        self.lvalue = true
    end
    return self
end
function T.tree:withtype(type) -- for typed tree
    assert(terra.types.istype(type))
    self.type = type
    return self
end
-- END TYPE

-- SPECIALIZATION (removal of escape expressions, escape sugar, evaluation of type expressoins)

--convert a lua value 'v' into the terra tree representing that value
function terra.createterraexpression(diag,anchor,v)
    local function createsingle(v)
        if terra.isglobalvar(v) or terra.issymbol(v) then
            local name = T.var:isclassof(anchor) and anchor.name --propage original variable name for debugging purposes
            return newobject(anchor,terra.isglobalvar(v) and T.globalvar or T.var,name or tostring(v),v):setlvalue(true)
        elseif terra.isquote(v) then
            if not terra.istree(v.tree) then
                print(v.tree)
            end
            assert(terra.istree(v.tree))
            return v.tree
        elseif terra.istree(v) then
            --if this is a raw tree, we just drop it in place and hope the user knew what they were doing
            return v
        elseif type(v) == "cdata" then
            local typ = terra.typeof(v)
            if typ:isaggregate() then --when an aggregate is directly referenced from Terra we get its pointer
                                      --a constant would make an entire copy of the object
                local ptrobj = createsingle(terra.constant(terra.types.pointer(typ),v))
                return newobject(anchor,T.operator, "@", List { ptrobj })
            end
            return createsingle(terra.constant(typ,v))
        elseif type(v) == "number" or type(v) == "boolean" or type(v) == "string" then
            return createsingle(terra.constant(v))
        elseif terra.isconstant(v) then
            if v.stringvalue then --strings are handled specially since they are a pointer type (rawstring) but the constant is actually string data, not just the pointer
                return newobject(anchor,T.literal,v.stringvalue,terra.types.rawstring)
            else 
                return newobject(anchor,T.constant,v,v.type):setlvalue(v.type:isaggregate())
            end
        end
        local mt = getmetatable(v)
        if type(mt) == "table" and mt.__toterraexpression then
            return terra.createterraexpression(diag,anchor,mt.__toterraexpression(v))
        else
            if not (terra.isfunction(v) or terra.ismacro(v) or terra.types.istype(v) or type(v) == "table") then
                diag:reporterror(anchor,"lua object of type ", terra.type(v), " not understood by terra code.")
                if type(v) == "function" then
                    diag:reporterror(anchor, "to call a lua function from terra first use terralib.cast to cast it to a terra function type.")
                end
            end
            return newobject(anchor,T.luaobject,v)
        end
    end
    if terra.israwlist(v) then
        local values = terra.newlist()
        for _,i in ipairs(v) do
            values:insert(createsingle(i))
        end
        return newobject(anchor,T.treelist,values)
    else
        return createsingle(v)
    end
end

function terra.specialize(origtree, luaenv, depth)
    local env = terra.newenvironment(luaenv)
    local diag = terra.newdiagnostics()
    diag:begin()
    local translatetree, translategenerictree, translatelist, resolvetype, createformalparameterlist
    local function evaltype(anchor,typ)
        local success, v = terra.evalluaexpression(diag,env:combinedenv(),typ)
        if success and terra.types.istype(v) then return v end
        if success and terra.israwlist(v) then
            for i,t in ipairs(v) do
                if not terra.types.istype(t) then
                    diag:reporterror(anchor,"expected a type but found ",terra.type(v))
                    return terra.types.error
                end
            end
            return #v == 1 and v[1] or terra.types.tuple(unpack(v))
        end
        if success then
            diag:reporterror(anchor,"expected a type but found ",terra.type(v))
        end
        return terra.types.error
    end
    local function translateident(e,stringok)
        if e.kind == "namedident" then return e end
        local success, r = terra.evalluaexpression(diag,env:combinedenv(),e.expression)
        if type(r) == "string" then
            if not stringok then
                diag:reporterror(e,"expected a symbol but found string")
                return newobject(e,T.symbolident,terra.newsymbol(r))
            end
            return newobject(e,T.namedident,r)
        elseif not terra.issymbol(r) then
            if success then
                diag:reporterror(e,"expected a string or symbol but found ",terra.type(r))
            end
            r = terra.newsymbol(nil,"error")
        end
        return newobject(e,T.symbolident,r)
    end
    function translatetree(e)
        if T.var:isclassof(e) then
            local v = env:combinedenv()[e.name]
            if v == nil then
                diag:reporterror(e,"variable '"..e.name.."' not found")
                return e
            end
            return terra.createterraexpression(diag,e,v)
        elseif T.selectu:isclassof(e) then
            local ee = translategenerictree(e)
            if not ee.value:is "luaobject" then
                return ee
            end
            --note: luaobject only appear due to tree translation, so we can safely mutate ee
            local value,field = ee.value.value, ee.field.value
            if type(value) ~= "table" then
                diag:reporterror(e,"expected a table but found ", terra.type(value))
                return ee
            end

            if terra.types.istype(value) and value:isstruct() then --class method lookup, this is handled when typechecking
                return ee
            end

            local success,selected = terra.invokeuserfunction(e,false,function() return value[field] end)
            if not success or selected == nil then
                diag:reporterror(e,"no field ", field," in lua object")
                return ee
            end
            return terra.createterraexpression(diag,e,selected)
        elseif T.luaexpression:isclassof(e) then
            local value = {}
            if e.isexpression then
                local success, returnvalue = terra.evalluaexpression(diag,env:combinedenv(),e)
                if success then value = returnvalue end
            else
                env:enterblock()
                env:localenv().emit = function(arg) table.insert(value,arg) end
                terra.evalluaexpression(diag,env:combinedenv(),e)
                env:leaveblock()
            end
            return terra.createterraexpression(diag, e, value)
        elseif T.ident:isclassof(e) then
            return translateident(e,true)
        elseif T.defvar:isclassof(e) then
            local initializers = translatelist(e.initializers)
            local variables = createformalparameterlist(e.variables, not e.hasinit)
            return newobject(e,T.defvar,variables,e.hasinit,initializers)
        elseif T.functiondefu:isclassof(e) then
            local parameters = createformalparameterlist(e.parameters,true)
            local returntype = e.returntype and evaltype(e,e.returntype)
            local body = translatetree(e.body)
            return newobject(e,T.functiondefu,parameters,e.is_varargs,returntype,body)
        elseif T.fornumu:isclassof(e) then
            local initial,limit,step = translatetree(e.initial),translatetree(e.limit), e.step and translatetree(e.step)
            env:enterblock()
            local variables = createformalparameterlist(terra.newlist { e.variable }, false)
            if #variables ~= 1 then
                diag:reporterror(e.variable, "expected a single iteration variable but found ",#variables)
            end
            local body = translatetree(e.body)
            env:leaveblock()
            return newobject(e,T.fornumu,variables[1],initial,limit,step,body)
        elseif T.forlist:isclassof(e) then
            local iterator = translatetree(e.iterator)
            env:enterblock()
            local variables = createformalparameterlist(e.variables,false)
            local body = translatetree(e.body)
            env:leaveblock()
            return newobject(e,T.forlist,variables,iterator,body)
        elseif T.block:isclassof(e) then
            env:enterblock()
            local r = translatelist(e.statements)
            env:leaveblock()
            if r == e.statements then return e
            else return newobject(e,T.block,r) end
        elseif T.repeatstat:isclassof(e) then
            --special handling for order of repeat
            local ns = translatelist(e.statements)
            local nc = translatetree(e.condition)
            if ns == e.statements and nc == e.condition then
                return e
            end
            return newobject(e,T.repeatstat,ns,nc)
        elseif T.letin:isclassof(e) then
            --special handling for ordering of letin
            local ns = translatelist(e.statements)
            local ne = translatelist(e.expressions)
            if ns == e.statements and ne == e.expressions then
                return e
            end
            return newobject(e,T.letin,ns,ne,e.hasstatements)
        else
            return translategenerictree(e)
        end
    end
    function createformalparameterlist(paramlist, requiretypes)
        local function registername(p,name,sym)
            local lenv = env:localenv()
            if rawget(lenv,name) then
                diag:reporterror(p,"duplicate definition of variable ",name)
            end
            lenv[name] = sym
        end
                
        local result = terra.newlist()
        for i,p in ipairs(paramlist) do
            local evaltype = p.type and evaltype(p,p.type)
            if p.name.kind == "namedident" then
                local sym = terra.newsymbol(nil,p.name.value)
                registername(p,p.name.value,sym)
                result:insert(newobject(p,T.concreteparam,evaltype,p.name.value,sym))
            else assert(p.name.kind == "escapedident")
                if p.type then
                    local symident = translateident(p.name,false)
                    result:insert(newobject(p,T.concreteparam,evaltype,tostring(symident.value),symident.value))
                else
                    local success, value = terra.evalluaexpression(diag,env:combinedenv(),p.name.expression)
                    if success then
                        if not value then
                            diag:reporterror(p,"expected a symbol or string but found nil")
                        end
                        local symlist = (terra.israwlist(value) and value) or terra.newlist{ value }
                        for i,entry in ipairs(symlist) do
                            if terra.issymbol(entry) then
                                result:insert(newobject(p,T.concreteparam,nil,tostring(entry),entry))
                            else
                                diag:reporterror(p,"expected a symbol but found ",terra.type(entry))
                            end
                        end
                    end
                end
            end
        end
        for i,entry in ipairs(result) do
            local sym = entry.symbol
            entry.type = entry.type or sym.type --if the symbol was given a type but the parameter didn't have one
                                                --it takes the type of the symbol
            assert(entry.type == nil or terra.types.istype(entry.type))
            if requiretypes and not entry.type then
                diag:reporterror(entry,"type must be specified for parameters and uninitialized variables")
            end
        end
        return result
    end
    --recursively translate any tree or list of trees.
    --new objects are only created when we find a new value
    function translategenerictree(tree)
        local function isasdl(tree)
            local metatable = getmetatable(tree)
            return type(tree) == "table" and type(metatable) == "table" and type(rawget(metatable,"__fields")) == "table"
        end
        if not isasdl(tree) then
            terra.printraw(tree)
        end
        assert(isasdl(tree))
        local nt = nil
        local function addentry(k,origv,newv)
            if origv ~= newv then
                if not nt then
                    nt = copyobject(tree,{})
                end
                nt[k] = newv
            end
        end
        for _,f in ipairs(tree.__fields) do
            local v = tree[f.name]
            if isasdl(v) then
                addentry(f.name,v,translatetree(v))
            elseif List:isclassof(v) and #v > 0 and isasdl(v[1]) then
                addentry(f.name,v,translatelist(v))
            end 
        end
        return nt or tree
    end
    function translatelist(lst)
        local changed = false
        local nl = lst:map(function(e)
            local ee = translatetree(e)
            changed = changed or ee ~= e
            return ee
        end)
        return (changed and nl) or lst
    end
    
    dbprint(2,"specializing tree")
    dbprintraw(2,origtree)

    local newtree = translatetree(origtree)
    
    diag:finishandabortiferrors("Errors reported during specialization.",depth+1)
    return newtree
end

-- TYPECHECKER

function terra.evalluaexpression(diag, env, e)
    local function parseerrormessage(startline, errmsg)
        local line,err = errmsg:match [["$terra$"]:([0-9]+):(.*)]]
        if line and err then
            return startline + tonumber(line) - 1, err
        else
            return startline, errmsg
        end
    end
    if not T.luaexpression:isclassof(e) then
       error("not a lua expression?") 
    end
    assert(type(e.expression) == "function")
    local fn = e.expression
    local oldenv = getfenv(fn)
    setfenv(fn,env)
    local success,v = pcall(fn)
    setfenv(fn,oldenv) --otherwise, we hold false reference to env
    if not success then --v contains the error message
        local oldln,ln,err = e.linenumber,parseerrormessage(e.linenumber,v)
        e.linenumber = ln
        diag:reporterror(e,"error evaluating lua code: ", diag.source, "lua error was:\n", err)
        e.linenumber = oldln
        return false
    end
    return true,v
end

--all calls to user-defined functions from the compiler go through this wrapper
function terra.invokeuserfunction(anchor, speculate, userfn,  ...)
    local args = {...}
    local results = { xpcall(function() return userfn(unpack(args)) end,debug.traceback) }
    if not speculate and not results[1] then
        local diag = terra.getcompilecontext().diagnostics
        diag:reporterror(anchor,"error while invoking macro or metamethod: ",results[2])
    end
    return unpack(results)
end

local unsafesymbolenv
function terra.unsafetypeofsymbol(sym)
    assert(terra.issymbol(sym))
    local def = unsafesymbolenv:localenv()[sym]
    return def.type
end

function terra.funcdefinition:typecheckbody()    
    assert(self.state == "untyped")
    self.state = "typechecking"
    if self.isextern then
        self.type:completefunction(self.untypedtree)
        return self.type
    end
    local ctx = terra.getcompilecontext()
    local starttime = terra.currenttimeinseconds()
    
    --initialization

    dbprint(2,"compiling function:")
    dbprintraw(2,self.untypedtree)

    local ftree = self.untypedtree
    
    local symbolenv = terra.newenvironment()
    
    --temporary hack to expose a way to map symbols to their type outside of the typechecker
    --this interface will change in the future
    local oldsymbolenv = unsafesymbolenv
    unsafesymbolenv = symbolenv
    
    local diag = terra.getcompilecontext().diagnostics

    -- TYPECHECKING FUNCTION DECLARATIONS
    --declarations major driver functions for typechecker
    local checkexp -- (e.g. 3 + 4)
    local checkstmt -- (e.g. var a = 3)
    local checkcall -- any invocation (method, function call, macro, overloaded operator) gets translated into a call to checkcall (e.g. sizeof(int), foobar(3), obj:method(arg))
    local checklet -- (e.g. 3,4 of foo(3,4))
    local function checktree(tree,location)
        if location == "statement" then
            return checkstmt(tree)
        else
            return checkexp(tree,location)
        end
    end
    
    --tree constructors for trees created in the typechecking process
    local function createcast(exp,typ)
        return newobject(exp,T.cast,typ,exp,false):withtype(typ:complete(exp))
    end
    
    local validkeystack = { {} }
    local validexpressionkeys = { [validkeystack[1]] = true}
    local function entermacroscope()
        local k = {}
        validexpressionkeys[k] = true
        table.insert(validkeystack,k)
        diag:begin()
    end
    local function leavemacroscope(anchor)
        local k = table.remove(validkeystack)
        validexpressionkeys[k] = nil
        if diag:finish() then
            diag:reporterror(anchor,"previous errors occurred while typechecking this macro")
        end
    end
    local function createtypedexpression(exp)
        return newobject(exp,T.typedexpression,exp,validkeystack[#validkeystack])
    end
    local function createfunctionliteral(anchor,e)
        local fntyp = e:gettype(nil,assert(anchor))
        local typ = terra.types.pointer(fntyp)
        return newobject(anchor,T.literal,e,typ)
    end
    
    local function insertaddressof(ee)
        return newobject(ee,T.operator,"&",List {ee}):withtype(terra.types.pointer(ee.type))
    end
    
    local function insertdereference(e)
        local ret = newobject(e,T.operator,"@",List{e}):setlvalue(true)
        if not e.type:ispointer() then
            diag:reporterror(e,"argument of dereference is not a pointer type but ",e.type)
            ret:withtype(terra.types.error)
        else
            ret:withtype(e.type.type:complete(e))
        end
        return ret
    end

    local function insertselect(v, field)
        assert(v.type:isstruct())

        local layout = v.type:getlayout(v)
        local index = layout.keytoindex[field]
        
        if index == nil then
            return nil,false
        end

        local type = layout.entries[index+1].type:complete(v)
        local tree = newobject(v,T.select,v,index,tostring(field)):setlvalue(v.lvalue):withtype(type)
        return tree,true
    end

    local function ensurelvalue(e)
        if not e.lvalue then
            diag:reporterror(e,"argument to operator must be an lvalue")
        end
        return e
    end

    --functions handling casting between types
    
    local insertcast --handles implicitly allowed casts (e.g. var a : int = 3.5)
    local insertexplicitcast --handles casts performed explicitly (e.g. var a = int(3.5))
    local structcast -- handles casting from an anonymous structure type to another struct type (e.g. StructFoo { 3, 5 })
    local insertrecievercast -- handles casting for method recievers, which allows for an implicit addressof operator to be inserted
    -- all implicit casts (struct,reciever,generic) take a speculative argument
    --if speculative is true, then errors will not be reported (caller must check)
    --this is used to see if an overloaded function can apply to the argument list
    
    --create a new variable allocation and a var node that refers to it, used to create temporary variables
    local function allocvar(anchor,typ,name)
        local av = newobject(anchor,T.allocvar,name,terra.newsymbol(name)):setlvalue(true):withtype(typ:complete(anchor))
        local v = newobject(anchor,T.var,name,av.symbol):setlvalue(true):withtype(typ)
        v.definition = av
        return av,v
    end
    
    function structcast(explicit,exp,typ, speculative)
        local from = exp.type:getlayout(exp)
        local to = typ:getlayout(exp)

        local valid = true
        local function err(...)
            valid = false
            if not speculative then
                diag:reporterror(exp,...)
            end
        end
        local structvariable, var_ref = allocvar(exp,exp.type,"<structcast>")
        
        local entries = List()
        if #from.entries > #to.entries or (not explicit and #from.entries ~= #to.entries) then
            err("structural cast invalid, source has ",#from.entries," fields but target has only ",#to.entries)
            return exp:copy{}:withtype(typ), valid
        end
        for i,entry in ipairs(from.entries) do
            local selected = insertselect(var_ref,entry.key)
            local offset = exp.type.convertible == "tuple" and i - 1 or to.keytoindex[entry.key]
            if not offset then
                err("structural cast invalid, result structure has no key ", entry.key)
            else
                local v = insertcast(selected,to.entries[offset+1].type)
                entries:insert(newobject(exp,T.storelocation,offset,v))
            end
        end
        return newobject(exp,T.structcast,structvariable,exp,entries):withtype(typ)
    end
    
    function insertcast(exp,typ,speculative) --if speculative is true, then an error will not be reported and the caller should check the second return value to see if the cast was valid
        if typ == nil or not terra.types.istype(typ) or not exp.type then
            print(debug.traceback())
        end
        if typ == exp.type or typ == terra.types.error or exp.type == terra.types.error then
            return exp, true
        else
            if ((typ:isprimitive() and exp.type:isprimitive()) or
                (typ:isvector() and exp.type:isvector() and typ.N == exp.type.N)) and
               not typ:islogicalorvector() and not exp.type:islogicalorvector() then
                return createcast(exp,typ), true
            elseif typ:ispointer() and exp.type:ispointer() and typ.type == terra.types.opaque then --implicit cast from any pointer to &opaque
                return createcast(exp,typ), true
            elseif typ:ispointer() and exp.type == terra.types.niltype then --niltype can be any pointer
                return createcast(exp,typ), true
            elseif typ:isstruct() and typ.convertible and exp.type:isstruct() and exp.type.convertible then 
                return structcast(false,exp,typ,speculative), true
            elseif typ:ispointer() and exp.type:isarray() and typ.type == exp.type.type then
                return createcast(exp,typ), true
            elseif typ:isvector() and exp.type:isprimitive() then
                local primitivecast, valid = insertcast(exp,typ.type,speculative)
                local broadcast = createcast(primitivecast,typ)
                return broadcast, valid
            end

            --no builtin casts worked... now try user-defined casts
            local cast_fns = terra.newlist()
            local function addcasts(typ)
                if typ:isstruct() and typ.metamethods.__cast then
                    cast_fns:insert(typ.metamethods.__cast)
                elseif typ:ispointertostruct() then
                    addcasts(typ.type)
                end
            end
            addcasts(exp.type)
            addcasts(typ)

            local errormsgs = terra.newlist()
            for i,__cast in ipairs(cast_fns) do
                entermacroscope()
                local quotedexp = terra.newquote(createtypedexpression(exp))
                local success,result = terra.invokeuserfunction(exp, true,__cast,exp.type,typ,quotedexp)
                if success then
                    local result = checkexp(terra.createterraexpression(diag,exp,result))
                    if result.type ~= typ then 
                        diag:reporterror(exp,"user-defined cast returned expression with the wrong type.")
                    end
                    leavemacroscope(exp)
                    return result,true
                else
                    leavemacroscope(exp)
                    errormsgs:insert(result)
                end
            end

            if not speculative then
                diag:reporterror(exp,"invalid conversion from ",exp.type," to ",typ)
                for i,e in ipairs(errormsgs) do
                    diag:reporterror(exp,"user-defined cast failed: ",e)
                end
            end
            return createcast(exp,typ), false
        end
    end
    function insertexplicitcast(exp,typ) --all implicit casts are allowed plus some additional casts like from int to pointer, pointer to int, and int to int
        if typ == exp.type then
            return exp
        elseif typ:ispointer() and exp.type:ispointer() then
            return createcast(exp,typ)
        elseif typ:ispointer() and exp.type:isintegral() then --int to pointer
            return createcast(exp,typ)
        elseif typ:isintegral() and exp.type:ispointer() then
            if typ.bytes < terra.types.intptr.bytes then
                diag:reporterror(exp,"pointer to ",typ," conversion loses precision")
            end
            return createcast(exp,typ)
        elseif (typ:isprimitive() and exp.type:isprimitive())
            or (typ:isvector() and exp.type:isvector() and typ.N == exp.type.N) then --explicit conversions from logicals to other primitives are allowed
            return createcast(exp,typ)
        elseif typ:isstruct() and exp.type:isstruct() and exp.type.convertible then 
            return structcast(true,exp,typ)
        else
            return insertcast(exp,typ) --otherwise, allow any implicit casts
        end
    end
    function insertrecievercast(exp,typ,speculative) --casts allow for method recievers a:b(c,d) ==> b(a,c,d), but 'a' has additional allowed implicit casting rules
                                                      --type can also be == "vararg" if the expected type of the reciever was an argument to the varargs of a function (this often happens when it is a lua function)
         if typ == "vararg" then
             return insertaddressof(exp), true
         elseif typ:ispointer() and not exp.type:ispointer() then
             --implicit address of allowed for recievers
             return insertcast(insertaddressof(exp),typ,speculative)
         else
            return insertcast(exp,typ,speculative)
        end
        --notes:
        --we force vararg recievers to be a pointer
        --an alternative would be to return reciever.type in this case, but when invoking a lua function as a method
        --this would case the lua function to get a pointer if called on a pointer, and a value otherwise
        --in other cases, you would consistently get a value or a pointer regardless of receiver type
        --for consistency, we all lua methods take pointers
        --TODO: should we also consider implicit conversions after the implicit address/dereference? or does it have to match exactly to work?
    end


    --functions to typecheck operator expressions
    
    local function typemeet(op,a,b)
        local function err()
            diag:reporterror(op,"incompatible types: ",a," and ",b)
        end
        if a == terra.types.error or b == terra.types.error then
            return terra.types.error
        elseif a == b then
            return a
        elseif a.kind == tokens.primitive and b.kind == tokens.primitive then
            if a:isintegral() and b:isintegral() then
                if a.bytes < b.bytes then
                    return b
                elseif a.bytes > b.bytes then
                    return a
                elseif a.signed then
                    return b
                else --a is unsigned but b is signed
                    return a
                end
            elseif a:isintegral() and b:isfloat() then
                return b
            elseif a:isfloat() and b:isintegral() then
                return a
            elseif a:isfloat() and b:isfloat() then
                return terra.types.double
            else
                err()
                return terra.types.error
            end
        elseif a:ispointer() and b == terra.types.niltype then
            return a
        elseif a == terra.types.niltype and b:ispointer() then
            return b
        elseif a:isvector() and b:isvector() and a.N == b.N then
            local rt = typemeet(op,a.type,b.type)
            return (rt == terra.types.error and rt) or terra.types.vector(rt,a.N)
        elseif (a:isvector() and b:isprimitive()) or (b:isvector() and a:isprimitive()) then
            if a:isprimitive() then
                a,b = b,a --ensure a is vector and b is primitive
            end
            local rt = typemeet(op,a.type,b)
            return (rt == terra.types.error and rt) or terra.types.vector(rt,a.N)
        elseif a:isstruct() and b:isstruct() and a.convertible == "tuple" and b.convertible == "tuple" and #a.entries == #b.entries then
            local entries = terra.newlist()
            local as,bs = a:getentries(),b:getentries()
            for i,ae in ipairs(as) do
                local be = bs[i]
                local rt = typemeet(op,ae.type,be.type)
                if rt == terra.types.error then return rt end
                entries:insert(rt)
            end
            return terra.types.tuple(unpack(entries))
        else    
            err()
            return terra.types.error
        end
    end

    local function typematch(op,lstmt,rstmt)
        local inputtype = typemeet(op,lstmt.type,rstmt.type)
        return inputtype, insertcast(lstmt,inputtype), insertcast(rstmt,inputtype)
    end

    local function checkunary(ee,operands,property)
        local e = operands[1]
        if e.type ~= terra.types.error and not e.type[property](e.type) then
            diag:reporterror(e,"argument of unary operator is not valid type but ",e.type)
            return e:aserror()
        end
        return ee:copy { operands = List{e} }:withtype(e.type)
    end 
    
    
    local function meetbinary(e,property,lhs,rhs)
        local t,l,r = typematch(e,lhs,rhs)
        if t ~= terra.types.error and not t[property](t) then
            diag:reporterror(e,"arguments of binary operator are not valid type but ",t)
            return e:aserror()
        end
        return e:copy { operands = List {l,r} }:withtype(t)
    end
    
    local function checkbinaryorunary(e,operands,property)
        if #operands == 1 then
            return checkunary(e,operands,property)
        end
        return meetbinary(e,property,operands[1],operands[2])
    end
    
    local function checkarith(e,operands)
        return checkbinaryorunary(e,operands,"isarithmeticorvector")
    end

    local function checkarithpointer(e,operands)
        if #operands == 1 then
            return checkunary(e,operands,"isarithmeticorvector")
        end
        
        local l,r = unpack(operands)
        
        local function pointerlike(t)
            return t:ispointer() or t:isarray()
        end
        local function ascompletepointer(exp) --convert pointer like things into pointers to _complete_ types
            exp.type.type:complete(exp)
            return (insertcast(exp,terra.types.pointer(exp.type.type))) --parens are to truncate to 1 argument
        end
        -- subtracting 2 pointers
        if  pointerlike(l.type) and pointerlike(r.type) and l.type.type == r.type.type and e.operator == tokens["-"] then
            return e:copy { operands = List {ascompletepointer(l),ascompletepointer(r)} }:withtype(terra.types.ptrdiff)
        elseif pointerlike(l.type) and r.type:isintegral() then -- adding or subtracting a int to a pointer
            return e:copy {operands = List {ascompletepointer(l),r} }:withtype(terra.types.pointer(l.type.type))
        elseif l.type:isintegral() and pointerlike(r.type) then
            return e:copy {operands = List {ascompletepointer(r),l} }:withtype(terra.types.pointer(r.type.type))
        else
            return meetbinary(e,"isarithmeticorvector",l,r)
        end
    end

    local function checkintegralarith(e,operands)
        return checkbinaryorunary(e,operands,"isintegralorvector")
    end
    
    local function checkcomparision(e,operands)
        local t,l,r = typematch(e,operands[1],operands[2])
        local rt = terra.types.bool
        if t:isaggregate() then
            diag:reporterror(e,"cannot compare aggregate type ",t)
        elseif t:isvector() then
            rt = terra.types.vector(terra.types.bool,t.N)
        end
        return e:copy { operands = List {l,r} }:withtype(rt)
    end
    
    local function checklogicalorintegral(e,operands)
        return checkbinaryorunary(e,operands,"canbeordorvector")
    end
    
    local function checkshift(ee,operands)
        local a,b = unpack(operands)
        local typ = terra.types.error
        if a.type ~= terra.types.error and b.type ~= terra.types.error then
            if a.type:isintegralorvector() and b.type:isintegralorvector() then
                if a.type:isvector() then
                    typ = a.type
                elseif b.type:isvector() then
                    typ = terra.types.vector(a.type,b.type.N)
                else
                    typ = a.type
                end
                
                a = insertcast(a,typ)
                b = insertcast(b,typ)
            
            else
                diag:reporterror(ee,"arguments to shift must be integers but found ",a.type," and ", b.type)
            end
        end
        
        return ee:copy { operands =  List{a,b} }:withtype(typ)
    end
    
    
    local function checkifelse(ee,operands)
        local cond = operands[1]
        local t,l,r = typematch(ee,operands[2],operands[3])
        if cond.type ~= terra.types.error and t ~= terra.types.error then
            if cond.type:isvector() and cond.type.type == terra.types.bool then
                if not t:isvector() or t.N ~= cond.type.N then
                    diag:reporterror(ee,"conditional in select is not the same shape as ",cond.type)
                end
            elseif cond.type ~= terra.types.bool then
                diag:reporterror(ee,"expected a boolean or vector of booleans but found ",cond.type)   
            end
        end
        return ee:copy {operands = List {cond,l,r}}:withtype(t)
    end

    local operator_table = {
        ["-"] = { checkarithpointer, "__sub", "__unm" };
        ["+"] = { checkarithpointer, "__add" };
        ["*"] = { checkarith, "__mul" };
        ["/"] = { checkarith, "__div" };
        ["%"] = { checkarith, "__mod" };
        ["<"] = { checkcomparision, "__lt" };
        ["<="] = { checkcomparision, "__le" };
        [">"] = { checkcomparision, "__gt" };
        [">="] =  { checkcomparision, "__ge" };
        ["=="] = { checkcomparision, "__eq" };
        ["~="] = { checkcomparision, "__ne" };
        ["and"] = { checklogicalorintegral, "__and" };
        ["or"] = { checklogicalorintegral, "__or" };
        ["not"] = { checklogicalorintegral, "__not" };
        ["^"] =  { checkintegralarith, "__xor" };
        ["<<"] = { checkshift, "__lshift" };
        [">>"] = { checkshift, "__rshift" };
        ["select"] = { checkifelse, "__select"}
    }
    
    local defersinlocalscope,checklocaldefers --functions used to determine if defer statements are in the wrong places
                                              --defined with machinery for checking statements
    
    local function checkoperator(ee)
        local op_string = ee.operator
        
        --check non-overloadable operators first
        if op_string == "@" then
            local e = checkexp(ee.operands[1])
            return insertdereference(e)
        elseif op_string == "&" then
            local e = ensurelvalue(checkexp(ee.operands[1]))
            local ty = terra.types.pointer(e.type)
            return ee:copy { operands = List {e} }:withtype(ty)
        end
        
        local op, genericoverloadmethod, unaryoverloadmethod = unpack(operator_table[op_string] or {})
        
        if op == nil then
            diag:reporterror(ee,"operator ",op_string," not defined in terra code.")
            return ee:aserror()
        end
        
        local ndefers = defersinlocalscope()
        local operands = ee.operands:map(checkexp)
        
        local overloads = terra.newlist()
        for i,e in ipairs(operands) do
            if e.type:isstruct() then
                local overloadmethod = (#operands == 1 and unaryoverloadmethod) or genericoverloadmethod
                local overload = e.type.metamethods[overloadmethod] --TODO: be more intelligent here about merging overloaded functions so that all possibilities are considered
                if overload then
                    overloads:insert(terra.createterraexpression(diag, ee, overload))
                end
            end
        end
        
        if #overloads > 0 then
            return checkcall(ee, overloads, operands, "all", true, "expression")
        else
            local r = op(ee,operands)
            if (op_string == "and" or op_string == "or") and operands[1].type:islogical() then
                checklocaldefers(ee, ndefers)
            end
            return r
        end
    end

    --functions to handle typecheck invocations (functions,methods,macros,operator overloads)
    local function removeluaobject(e)
        if not e:is "luaobject" or e.type == terra.types.error then 
            return e --don't repeat error messages
        elseif terra.isfunction(e.value) then
            local definitions = e.value:getdefinitions()
            if #definitions ~= 1 then
                diag:reporterror(e,(#definitions == 0 and "undefined") or "overloaded", " functions cannot be used as values")
                return e:aserror()
            end
            return createfunctionliteral(e,definitions[1])
        else
            if terra.types.istype(e.value) then
                diag:reporterror(e, "expected a terra expression but found terra type ", tostring(e.value), ". If this is a cast, you may have omitted the required parentheses: [T](exp)")
            else
                diag:reporterror(e, "expected a terra expression but found ",terra.type(e.value))
            end
            return e:aserror()
        end
    end
    
    local function checkexpressions(expressions,location)
        local nes = terra.newlist()
        for i,e in ipairs(expressions) do
            local ne = checkexp(e,location)
            if ne:is "letin"  and not ne.hasstatements then
                nes:insertall(ne.expressions)
            else
                nes:insert(ne)
            end
        end
        return nes
    end
    
   function checklet(anchor, statements, expressions, hasstatements)
        local ns = statements:map(checkstmt)
        local ne = checkexpressions(expressions)
        local r = newobject(anchor,T.letin,ns,ne, hasstatements)
        if #ne == 1 then
            r:withtype(ne[1].type):setlvalue(ne[1].lvalue)
        else
            r:withtype(terra.types.tuple(unpack(ne:map("type"))))
        end
        r.type:complete(anchor)
        return r
    end
    
    local function insertvarargpromotions(param)
        if param.type == terra.types.float then
            return insertcast(param,terra.types.double)
        elseif param.type:isarray() then
            --varargs are only possible as an interface to C (or Lua) where arrays are not value types
            --this can cause problems (e.g. calling printf) when Terra passes the value
            --so we degrade the array into pointer when it is an argument to a vararg parameter
            return insertcast(param,terra.types.pointer(param.type.type))
        end
        --TODO: do we need promotions for integral data types or does llvm already do that?
        return param
    end

    local function tryinsertcasts(anchor, typelists,castbehavior, speculate, allowambiguous, paramlist)
        local PERFECT_MATCH,CAST_MATCH,TOP = 1,2,math.huge
         
        local function trylist(typelist, speculate)
            if #typelist ~= #paramlist then
                if not speculate then
                    diag:reporterror(anchor,"expected "..#typelist.." parameters, but found "..#paramlist)
                end
                return false
            end
            local results,matches = terra.newlist(),terra.newlist()
            for i,typ in ipairs(typelist) do
                local param,result,match,valid = paramlist[i]
                if typ == "passthrough" or typ == param.type then
                    result,match = param,PERFECT_MATCH
                else
                    match = CAST_MATCH
                    if castbehavior == "all" or i == 1 and castbehavior == "first" then
                        result,valid = insertrecievercast(param,typ,speculate)
                    elseif typ == "vararg" then
                        result,valid = insertvarargpromotions(param),true
                    else
                        result,valid = insertcast(param,typ,speculate)
                    end
                    if not valid then return false end
                end
                results[i],matches[i] = result,match
            end
            return true,results,matches
        end
        if #typelists == 1 then
            local valid,results = trylist(typelists[1],speculate)
            if not valid then
                return paramlist,nil
            else
                return results, 1
            end
        else
            local function meetwith(a,b)
                local ale, ble = true,true
                local meet = terra.newlist()
                for i = 1,#paramlist do
                    local m = math.min(a[i] or TOP,b[i] or TOP)
                    ale = ale and a[i] == m
                    ble = ble and b[i] == m
                    a[i] = m
                end
                return ale,ble --a = a meet b, a <= b, b <= a
            end

            local results,matches = terra.newlist(),terra.newlist()
            for i,typelist in ipairs(typelists) do
                local valid,nr,nm = trylist(typelist,true)
                if valid then
                    local ale,ble = meetwith(matches,nm)
                    if ale == ble then
                        if ale and not matches.exists then
                            results = terra.newlist()
                        end
                        results:insert( { expressions = nr, idx = i } )
                        matches.exists = ale
                    elseif ble then
                        results = terra.newlist { { expressions = nr, idx = i } }
                        matches.exists = true
                    end
                end
            end
            if #results == 0 then
                --no options were valid and our caller wants us to, lets emit some errors
                if not speculate then
                    diag:reporterror(anchor,"call to overloaded function does not apply to any arguments")
                    for i,typelist in ipairs(typelists) do
                        diag:reporterror(anchor,"option ",i," with type ",mkstring(typelist,"(",",",")"))
                        trylist(typelist,false)
                    end
                end
                return paramlist,nil
            else
                if #results > 1 and not allowambiguous then
                    local strings = results:map(function(x) return mkstring(typelists[x.idx],"type list (",",",") ") end)
                    diag:reporterror(anchor,"call to overloaded function is ambiguous. can apply to ",unpack(strings))
                end 
                return results[1].expressions, results[1].idx
            end
        end
    end
    
    local function insertcasts(anchor, typelist,paramlist) --typelist is a list of target types (or the value "passthrough"), paramlist is a parameter list that might have a multiple return value at the end
        return tryinsertcasts(anchor, terra.newlist { typelist }, "none", false, false, paramlist)
    end

    local function checkmethodwithreciever(anchor, ismeta, methodname, reciever, arguments, location)
        local objtyp
        reciever.type:complete(anchor)
        if reciever.type:isstruct() then
            objtyp = reciever.type
        elseif reciever.type:ispointertostruct() then
            objtyp = reciever.type.type
            reciever = insertdereference(reciever)
        else
            diag:reporterror(anchor,"attempting to call a method on a non-structural type ",reciever.type)
            return anchor:aserror()
        end

        local fnlike,errmsg
        if ismeta then
            fnlike = objtyp.metamethods[methodname]
            errmsg = fnlike == nil and "no such metamethodmethod "..methodname.." defined for type "..tostring(objtyp)
        else
            fnlike,errmsg = objtyp:getmethod(methodname)
        end

        if not fnlike then
            diag:reporterror(anchor,errmsg)
            return anchor:aserror()
        end

        fnlike = terra.createterraexpression(diag, anchor, fnlike) 
        local fnargs = terra.newlist { reciever }
        for i,a in ipairs(arguments) do
            fnargs:insert(a)
        end
        return checkcall(anchor, terra.newlist { fnlike }, fnargs, "first", false, location)
    end

    local function checkmethod(exp, location)
        local methodname = exp.name.value
        assert(type(methodname) == "string" or terra.issymbol(methodname))
        local reciever = checkexp(exp.value)
        local arguments = checkexpressions(exp.arguments,"luavalue")
        return checkmethodwithreciever(exp, false, methodname, reciever, arguments, location)
    end

    local function checkapply(exp, location)
        local fnlike = checkexp(exp.value,"luavalue")
        local arguments = checkexpressions(exp.arguments,"luavalue")
        if not fnlike:is "luaobject" then
            local typ = fnlike.type
            typ = typ:ispointer() and typ.type or typ
            if typ:isstruct() then
                if location == "lexpression" and typ.metamethods.__update then
                    local function setter(rhs)
                        arguments:insert(rhs)
                        return checkmethodwithreciever(exp, true, "__update", fnlike, arguments, "statement") 
                    end
                    return newobject(exp,T.setteru,setter)
                end
                return checkmethodwithreciever(exp, true, "__apply", fnlike, arguments, location) 
            end
        end
        return checkcall(exp, terra.newlist { fnlike } , arguments, "none", false, location)
    end
    local function createuntypedcast(value,totype,explicit)
        return newobject(value,T.cast,totype,value,explicit)
    end
    function checkcall(anchor, fnlikelist, arguments, castbehavior, allowambiguous, location)
        --arguments are always typed trees, or a lua object
        assert(#fnlikelist > 0)
        
        --collect all the terra functions, stop collecting when we reach the first 
        --macro and record it as themacro
        --we will first attempt to typecheck the terra functions, and if they fail,
        --we will call the macro/luafunction (these can take any argument types so they will always work)
        local terrafunctions = terra.newlist()
        local themacro = nil
        for i,fn in ipairs(fnlikelist) do
            if fn:is "luaobject" then
                if terra.ismacro(fn.value) then
                    themacro = fn.value
                    break
                elseif terra.types.istype(fn.value) then
                    local castmacro = terra.internalmacro(function(diag,tree,arg)
                        return createuntypedcast(arg.tree,fn.value,true)
                    end)
                    themacro = castmacro
                    break
                elseif terra.isfunction(fn.value) then
                    if #fn.value:getdefinitions() == 0 then
                        diag:reporterror(anchor,"attempting to call undefined function")
                    end
                    for i,v in ipairs(fn.value:getdefinitions()) do
                        local fnlit = createfunctionliteral(anchor,v)
                        if fnlit.type ~= terra.types.error then
                            terrafunctions:insert( fnlit )
                        end
                    end
                else
                    diag:reporterror(anchor,"expected a function or macro but found lua value of type ",terra.type(fn.value))
                end
            elseif fn.type:ispointer() and fn.type.type:isfunction() then
                terrafunctions:insert(fn)
            else
                if fn.type ~= terra.types.error then
                    diag:reporterror(anchor,"expected a function but found ",fn.type)
                end
            end 
        end

        local function createcall(callee, paramlist)
            callee.type.type:completefunction(anchor)
            return newobject(anchor,T.apply,callee,paramlist):withtype(callee.type.type.returntype)
        end
        
        if #terrafunctions > 0 then
            local paramlist = arguments:map(removeluaobject)
            local function getparametertypes(fn) --get the expected types for parameters to the call (this extends the function type to the length of the parameters if the function is vararg)
                local fntyp = fn.type.type
                if not fntyp.isvararg then return fntyp.parameters end
                local vatypes = terra.newlist()
                vatypes:insertall(fntyp.parameters)
                for i = 1,#paramlist - #fntyp.parameters do
                    vatypes:insert("vararg")
                end
                return vatypes
            end
            local typelists = terrafunctions:map(getparametertypes)
            local castedarguments,valididx = tryinsertcasts(anchor,typelists,castbehavior, themacro ~= nil, allowambiguous, paramlist)
            if valididx then
                return createcall(terrafunctions[valididx],castedarguments)
            end
        end

        if themacro then
            entermacroscope()

            local quotes = arguments:map(function(a)
                return terra.newquote(createtypedexpression(a))
            end)
            local success, result = terra.invokeuserfunction(anchor, false, themacro.run, themacro, diag, anchor, unpack(quotes))
            if success then
                local newexp = terra.createterraexpression(diag,anchor,result)
                result = checktree(newexp,location)
            else
                result = anchor:aserror()
            end
            
            leavemacroscope(anchor)
            return result
        end
        assert(diag:haserrors())
        return anchor:aserror()
    end

    --functions that handle the checking of expressions

    function checkexp(e_, location)
        location = location or "expression"
        assert(type(location) == "string")
        local function docheck(e)
            if not terra.istree(e) then
                print("not a tree?")
                print(debug.traceback())
                terra.printraw(e)
            end
            if e:is "luaobject" then
                return e
            elseif e:is "literal" then
                return e
            elseif e:is "constant"  then
                return e
            elseif e:is "var" then
                assert(terra.issymbol(e.symbol)) -- a symbol in the currently symbol environment
                local definition = symbolenv:localenv()[e.symbol]
                if not definition then
                    diag:reporterror(e, "definition of this variable is not in scope")
                    return e:aserror()
                end
                if not definition:is "allocvar" then
                    --this binding was introduced by a forlist statement
                    return checkexp(definition,location)
                end
                assert(terra.types.istype(definition.type))
                local r = e:copy{}:withtype(definition.type)
                r.definition = definition -- TODO: remove and have compiler handle this stuff
                return r
            elseif e:is "globalvar" then
                local r = e:copy{}:withtype(e.value.type)
                r.definition = e.value -- TODO: remove and have compiler handle this stuff
                return r
            elseif e:is "selectu" then
                local v = checkexp(e.value,"luavalue")
                local field = e.field.value
                --check for and handle Type.staticmethod
                if v:is "luaobject" and terra.types.istype(v.value) and v.value:isstruct() then
                    local fnlike, errmsg = v.value:getmethod(field)
                    if not fnlike then
                        diag:reporterror(e,errmsg)
                        return e:aserror()
                    end
                    return terra.createterraexpression(diag,e,fnlike)
                end
                
                v = removeluaobject(v)
                
                if v.type:ispointertostruct() then --allow 1 implicit dereference
                    v = insertdereference(v)
                end

                if v.type:isstruct() then
                    local ret, success = insertselect(v,field)
                    if not success then
                        --struct has no member field, call metamethod __entrymissing
                        local typ = v.type
                        
                        local function checkmacro(metamethod,arguments,location)
                            local named = terra.internalmacro(function(ctx,tree,...)
                                return typ.metamethods[metamethod]:run(ctx,tree,field,...)
                            end)
                            local getter = terra.createterraexpression(diag, e, named) 
                            return checkcall(v, terra.newlist{ getter }, arguments, "first", false, location)
                        end
                        if location == "lexpression" and typ.metamethods.__setentry then
                            local function setter(rhs)
                                return checkmacro("__setentry", terra.newlist { v , rhs }, "statement")
                            end
                            return newobject(v,T.setteru,setter)
                        elseif terra.ismacro(typ.metamethods.__entrymissing) then
                            return checkmacro("__entrymissing",terra.newlist { v },location)
                        else
                            diag:reporterror(v,"no field ",field," in terra object of type ",v.type)
                            return e:aserror()
                        end
                    else
                        return ret
                    end
                else
                    diag:reporterror(v,"expected a structural type")
                    return e:aserror()
                end
            elseif e:is "typedexpression" then --expression that has been previously typechecked and re-injected into the compiler
                if not validexpressionkeys[e.key] then --if it went through a macro, it could have been retained by lua code and returned to a different scope or even a different function
                                                       --we check that this didn't happen by checking that we are still inside the same scope where the expression was created
                    diag:reporterror(e,"cannot use a typed expression from one scope/function in another")
                    diag:reporterror(ftree,"typed expression used in this function.")
                end
                return e.expression
            elseif e:is "operator" then
                return checkoperator(e)
            elseif e:is "index" then
                local v = checkexp(e.value)
                local idx = checkexp(e.index)
                local typ,lvalue = terra.types.error, v.type:ispointer() or (v.type:isarray() and v.lvalue) 
                if v.type:ispointer() or v.type:isarray() or v.type:isvector() then
                    typ = v.type.type
                    if not idx.type:isintegral() and idx.type ~= terra.types.error then
                        diag:reporterror(e,"expected integral index but found ",idx.type)
                    end
                    if v.type:isarray() then
                        v = insertcast(v,terra.types.pointer(typ))
                    end
                else
                    if v.type ~= terra.types.error then
                        diag:reporterror(e,"expected an array or pointer but found ",v.type)
                    end
                end
                return e:copy { value = v, index = idx }:withtype(typ):setlvalue(lvalue)
            elseif e:is "cast" then
                return e.explicit and insertexplicitcast(checkexp(e.expression),e.to) or insertcast(checkexp(e.expression),e.to)
            elseif e:is "sizeof" then
                e.oftype:complete(e)
                return e:copy{}:withtype(terra.types.uint64)
            elseif e:is "vectorconstructor" or e:is "arrayconstructor" then
                local entries = checkexpressions(e.expressions)
                local N = #entries
                         
                local typ
                if e.oftype ~= nil then
                    typ = e.oftype:complete(e)
                else
                    if N == 0 then
                        diag:reporterror(e,"cannot determine type of empty aggregate")
                        return e:aserror()
                    end
                    
                    --figure out what type this vector has
                    typ = entries[1].type
                    for i,e2 in ipairs(entries) do
                        typ = typemeet(e,typ,e2.type)
                    end
                end
                
                local aggtype
                if e:is "vectorconstructor" then
                    if not typ:isprimitive() and typ ~= terra.types.error then
                        diag:reporterror(e,"vectors must be composed of primitive types (for now...) but found type ",terra.type(typ))
                        return e:aserror()
                    end
                    aggtype = terra.types.vector(typ,N)
                else
                    aggtype = terra.types.array(typ,N)
                end
                
                --insert the casts to the right type in the parameter list
                local typs = entries:map(function(x) return typ end)
                entries = insertcasts(e,typs,entries)
                return e:copy { expressions = entries }:withtype(aggtype)
            elseif e:is "attrload" then
                local addr = checkexp(e.address)
                if not addr.type:ispointer() then
                    diag:reporterror(e,"address must be a pointer but found ",addr.type)
                    return e:aserror()
                end
                return e:copy { address = addr }:withtype(addr.type.type)
            elseif e:is "attrstore" then
                local addr = checkexp(e.address)
                if not addr.type:ispointer() then
                    diag:reporterror(e,"address must be a pointer but found ",addr.type)
                    return e:aserror()
                end
                local value = insertcast(checkexp(e.value),addr.type.type)
                return e:copy { address = addr, value = value }:withtype(terra.types.unit:complete(e))
            elseif e:is "apply" then
                return checkapply(e,location)
            elseif e:is "method" then
                return checkmethod(e,location)
            elseif e:is "treelist" then
                return checklet(e,List {},e.trees, false)
            elseif e:is "letin" then
                symbolenv:enterblock()
                local result = checklet(e,e.statements,e.expressions,e.hasstatements)
                symbolenv:leaveblock()
                return result
           elseif e:is "constructoru" then
                local paramlist = terra.newlist()
                local named = 0
                for i,f in ipairs(e.records) do
                    local value = checkexp(f.value)
                    named = named + (f.key and 1 or 0)
                    if not f.key and value:is "letin" and not value.hasstatements then
                        paramlist:insertall(value.expressions)
                    else
                        paramlist:insert(value)
                    end
                end
                local typ = terra.types.error
                if named == 0 then
                    typ = terra.types.tuple(unpack(paramlist:map("type")))
                elseif named == #e.records then
                    typ = terra.types.newstructwithanchor("anon",e)
                    typ:setconvertible("named")
                    for i,e in ipairs(e.records) do
                        typ.entries:insert({field = e.key.value, type = paramlist[i].type})
                    end
                else
                    diag:reporterror(e, "some entries in constructor are named while others are not")
                end
                return newobject(e,T.constructor,paramlist):withtype(typ:complete(e))
            elseif e:is "inlineasm" then
                return e:copy { arguments = checkexpressions(e.arguments) }
            elseif e:is "debuginfo" then
                return e:copy{}:withtype(terra.types.unit:complete(e))
            else
                diag:reporterror(e,"statement found where an expression is expected ", e.kind)
                return e:aserror()
            end
        end
        
        local result = docheck(e_)
        --freeze all types returned by the expression (or list of expressions)
        if not result:is "luaobject" and not result:is "setteru" then
            assert(terra.types.istype(result.type))
            result.type:complete(result)
        end

        --remove any lua objects if they are not allowed in this context
        if location ~= "luavalue" then
            result = removeluaobject(result)
        end
        
        return result
    end

    --helper functions used in checking statements:
    
    local function checkexptyp(re,target)
        local e = checkexp(re)
        if e.type ~= target then
            diag:reporterror(e,"expected a ",target," expression but found ",e.type)
            e.type = terra.types.error
        end
        return e
    end
    local function checkcond(c)
        local N = defersinlocalscope()
        local r = checkexptyp(c,terra.types.bool)
        checklocaldefers(c,N)
        return r
    end
    local function checkcondbranch(s)
        local e = checkcond(s.condition)
        local body = checkstmt(s.body)
        return copyobject(s,{condition = e, body = body})
    end
    local function checkformalparameter(p)
        assert(type(p.name) == "string")
        assert(terra.issymbol(p.symbol))
        local r = newobject(p,T.allocvar,p.name,p.symbol):setlvalue(true)
        if p.type then
            assert(terra.types.istype(p.type))
            p.type:complete(p)
            r:withtype(p.type)
        end
        symbolenv:localenv()[p.symbol] = r
        return r
    end
    local function checkformalparameterlist(params)
        return params:map(checkformalparameter)
    end


    --state that is modified by checkstmt:
    
    local return_stmts = terra.newlist() --keep track of return stms, these will be merged at the end, possibly inserting casts
    
    local labels = {} --map from label name to definition (or, if undefined to the list of already seen gotos that target that label)
    local looppositions = List() -- stack of scopepositions that track where a break would go to
    local scopeposition = terra.newlist() --list(int), count of number of defer statements seens at each level of block scope, used for unwinding defer statements during break/goto
    
    
    local function getscopeposition()
        local sp = terra.newlist()
        for i,p in ipairs(scopeposition) do sp[i] = p end
        return sp
    end
    local function enterloop()
        looppositions:insert(getscopeposition())
    end
    local function leaveloop()
        looppositions:remove()
    end
    function defersinlocalscope()
        return scopeposition[#scopeposition]
    end
    function checklocaldefers(anchor,c)
        if defersinlocalscope() ~= c then
            diag:reporterror(anchor, "defer statements are not allowed in conditional expressions")
        end
    end
    --calculate the number of deferred statements that will fire when jumping from stack position 'from' to 'to'
    --if a goto crosses a deferred statement, we detect that and report an error
    local function numberofdeferredpassed(anchor,from,to)
        local N = math.max(#from,#to)
        for i = 1,N do
            local t,f = to[i] or 0, from[i] or 0
            if t < f then
                local c = f - t
                for j = i+1,N do
                    if (to[j] or 0) ~= 0 then
                        diag:reporterror(anchor,"goto crosses the scope of a deferred statement")
                    end
                    c = c + (from[j] or 0)
                end
                return c
            elseif t > f then
                diag:reporterror(anchor,"goto crosses the scope of a deferred statement")
                return 0
            end
        end
        return 0
    end
    local function createstatementlist(anchor,stmts)
        return newobject(anchor,T.letin, stmts, List {}, true):withtype(terra.types.unit:complete(anchor))
    end
    local function createassignment(anchor,lhs,rhs)
        if #lhs > #rhs and #rhs > 0 then
            local last = rhs[#rhs]
            if last.type:isstruct() and last.type.convertible == "tuple" and #last.type.entries + #rhs - 1 == #lhs then
                --struct pattern match
                local av,v = allocvar(anchor,last.type,"<structpattern>")
                local newlhs,lhsp,rhsp = terralib.newlist(),terralib.newlist(),terralib.newlist()
                for i,l in ipairs(lhs) do
                    if i < #rhs then
                        newlhs:insert(l)
                    else
                        lhsp:insert(l)
                        rhsp:insert((insertselect(v,"_"..tostring(i - #rhs))))
                    end
                end
                newlhs[#rhs] = av
                local a1,a2 = createassignment(anchor,newlhs,rhs), createassignment(anchor,lhsp,rhsp)
                return createstatementlist(anchor, List {a1, a2})
            end
        end
        local vtypes = lhs:map(function(v) return v.type or "passthrough" end)
        rhs = insertcasts(anchor,vtypes,rhs)
        for i,v in ipairs(lhs) do
            local rhstype = rhs[i] and rhs[i].type or terra.types.error
            if v:is "setteru" then
                local rv,r = allocvar(v,rhstype,"<rhs>")
                lhs[i] = newobject(v,T.setter, v.setter(r), rv)
            else
                ensurelvalue(v)
            end
            v.type = rhstype
        end
        return newobject(anchor,T.assignment,lhs,rhs)
    end
    -- checking of statements
    function checkstmt(s)
        if s:is "block" then
            symbolenv:enterblock()
            scopeposition:insert(0)
            local stats = s.statements:map(checkstmt)
            table.remove(scopeposition)
            symbolenv:leaveblock()
            return s:copy {statements = stats}
        elseif s:is "returnstat" then
            local rstmt = s:copy { expression = checkexp(s.expression) }
            return_stmts:insert( rstmt )
            return rstmt
        elseif s:is "label" then
            local ss = s:copy {}
            local label = ss.value.value
            ss.position = getscopeposition()
            local lbls = labels[label] or terra.newlist()
            if terra.istree(lbls) then
                diag:reporterror(s,"label defined twice")
                diag:reporterror(lbls,"previous definition here")
            else
                for _,v in ipairs(lbls) do
                    v.definition = ss
                    v.deferred = numberofdeferredpassed(v,v.position,ss.position)
                end
            end
            labels[label] = ss
            return ss
        elseif s:is "gotostat" then
            local ss = s:copy{}
            local label = ss.label.value
            local lbls = labels[label] or terra.newlist()
            if terra.istree(lbls) then
                ss.definition = lbls
                ss.deferred = numberofdeferredpassed(s,scopeposition,ss.definition.position)
            else
                ss.position = getscopeposition()
                lbls:insert(ss)
            end
            labels[label] = lbls
            return ss
        elseif s:is "breakstat" then
            local ss = s:copy({})
            if #looppositions == 0 then
                diag:reporterror(s,"break found outside a loop")
            else
                ss.deferred = numberofdeferredpassed(s,scopeposition,looppositions[#looppositions])
            end
            return ss
        elseif s:is "whilestat" then
            enterloop()
            local r = checkcondbranch(s)
            leaveloop()
            return r
        elseif s:is "fornumu" then
            local initial, limit, step = checkexp(s.initial), checkexp(s.limit), s.step and checkexp(s.step)
            local t = typemeet(initial,initial.type,limit.type) 
            t = step and typemeet(limit,t,step.type) or t
            enterloop()
            symbolenv:enterblock()
            local variable = checkformalparameter(s.variable)
            variable.type = variable.type or t
            if not variable.type:isintegral() then diag:reporterror(variable,"expected an integral type for loop initialization but found ",variable.type) end
            initial,step,limit = insertcast(initial,variable.type), step and insertcast(step,variable.type), insertcast(limit,variable.type)
            local body = checkstmt(s.body)
            symbolenv:leaveblock()
            leaveloop()
            local r = newobject(s,T.fornum,variable,initial,limit,step,body)
            return r
        elseif s:is "forlist" then
            local iterator = checkexp(s.iterator)
            local typ = iterator.type
            if typ:ispointertostruct() then
                typ,iterator = typ.type, insertdereference(iterator)
            end
            if not typ:isstruct() or type(typ.metamethods.__for) ~= "function" then
                diag:reporterror(iterator,"expected a struct with a __for metamethod but found ",typ)
                return s
            end
            local result,generator = s,typ.metamethods.__for
            entermacroscope()
            local symbols = s.variables:map("symbol")
            local success,variables,impl = terra.invokeuserfunction(s, false ,generator,symbols,terra.newquote(createtypedexpression(iterator)), terra.newquote(newobject(s,T.treelist,s.body.statements)))
            if success then
                if type(variables) ~= "table" then
                    diag:reporterror(iterator, "expected a table of variable bindings but found ", type(variables))
                elseif #variables ~= #s.variables then
                    diag:reporterror(iterator, "expected ", #s.variables, " variable bindings but found ", #variables)
                else
                    symbolenv:enterblock()
                    local lenv = symbolenv:localenv()
                    for i,e in ipairs(variables) do
                        local texp = terra.createterraexpression(diag,s.variables[i],e)
                        local typ = s.variables[i].type or symbols[i].type
                        if typ then
                            texp = createuntypedcast(texp,typ,false)
                        end
                        lenv[symbols[i]] = texp
                    end
                    result = checkstmt(terra.createterraexpression(diag,iterator,impl))
                    symbolenv:leaveblock()
                end
            end
            leavemacroscope(s)
            return result 
        elseif s:is "ifstat" then
            local br = s.branches:map(checkcondbranch)
            local els = (s.orelse and checkstmt(s.orelse))
            return s:copy{ branches = br, orelse = els }
        elseif s:is "repeatstat" then
            enterloop()
            local stmts = s.statements:map(checkstmt)
            local e = checkcond(s.condition)
            leaveloop()
            local r = s:copy { statements = stmts, condition = e }
            return r
        elseif s:is "defvar" then
            local rhs = s.hasinit and checkexpressions(s.initializers)
            local lhs = checkformalparameterlist(s.variables)
            local res = s.hasinit and createassignment(s,lhs,rhs) 
                        or createstatementlist(s,lhs)
            return res
        elseif s:is "assignment" then
            local rhs = checkexpressions(s.rhs)
            local lhs = checkexpressions(s.lhs,"lexpression")
            return createassignment(s,lhs,rhs)
        elseif s:is "apply" then
            return checkapply(s,"statement")
        elseif s:is "method" then
            return checkmethod(s,"statement")
        elseif s:is "treelist" then
            return checklet(s,s.trees,List(),true)
        elseif s:is "letin" then -- treat letin as a list of statement+expressions here, only create scope when in expressions
            return checklet(s,s.statements,s.expressions, true)
        elseif s:is "defer" then
            local call = checkexp(s.expression)
            if not call:is "apply" then
                diag:reporterror(s.expression,"deferred statement must resolve to a function call")
            end
            scopeposition[#scopeposition] = scopeposition[#scopeposition] + 1
            return s:copy { expression = call }
        else
            return checkexp(s)
        end
        error("NYI - "..s.kind,2)
    end
    


    -- actual implementation of typechecking the function begins here

    --  generate types for parameters, if return types exists generate a types for them as well
    local typed_parameters = checkformalparameterlist(ftree.parameters)
    local parameter_types = typed_parameters:map("type")

    local result = checkstmt(ftree.body)

    --check the label table for any labels that have been referenced but not defined
    for _,v in pairs(labels) do
        if not terra.istree(v) then
            diag:reporterror(v[1],"goto to undefined label")
        end
    end
    
    
    dbprint(2,"Return Stmts:")
    
    --calculate the return type based on either the declared return type, or the return statements
    local returntype = ftree.returntype or #return_stmts == 0 and terra.types.unit
    if not returntype then --calculate the meet of all return type to calculate the actual return type
        for _,stmt in ipairs(return_stmts) do
            local typ = stmt.expression.type
            returntype = returntype and typemeet(stmt.expression,returntype,typ) or typ
        end
    end
    
    local fntype = terra.types.functype(parameter_types,returntype,false):completefunction(ftree)

    --now cast each return expression to the expected return type
    for _,stmt in ipairs(return_stmts) do
        stmt.expression = insertcast(stmt.expression,returntype)
    end
    
    --we're done. build the typed tree for this function
    self.typedtree = newobject(ftree,T.functiondef,typed_parameters,ftree.is_varargs,fntype, result,labels)
    self.type = fntype

    self.stats.typec = terra.currenttimeinseconds() - starttime
    
    dbprint(2,"TypedTree")
    dbprintraw(2,self.typedtree)

    unsafesymbolenv = oldsymbolenv
    return fntype
end

-- END TYPECHECKER

-- INCLUDEC
local function includetableindex(tbl,name)    --this is called when a table returned from terra.includec doesn't contain an entry
    local v = getmetatable(tbl).errors[name]  --it is used to report why a function or type couldn't be included
    if v then
        error("includec: error importing symbol '"..name.."': "..v, 2)
    else
        error("includec: imported symbol '"..name.."' not found.",2)
    end
    return nil
end

terra.includepath = os.getenv("INCLUDE_PATH") or "."

local internalizedfiles = {}
local function fileparts(path)
    local fileseparators = ffi.os == "Windows" and "\\/" or "/"
    local pattern = "[%s]([^%s]*)"
    return path:gmatch(pattern:format(fileseparators,fileseparators))
end
function terra.registerinternalizedfiles(names,contents,sizes)
    names,contents,sizes = ffi.cast("const char **",names),ffi.cast("uint8_t **",contents),ffi.cast("int*",sizes)
    for i = 0,math.huge do
        if names[i] == nil then break end
        local name,content,size = ffi.string(names[i]),contents[i],sizes[i]
        local cur = internalizedfiles
        for segment in fileparts(name) do
            cur.children = cur.children or {}
            cur.kind = "directory"
            if not cur.children[segment] then
                cur.children[segment] = {} 
            end
            cur = cur.children[segment]
        end
        cur.contents,cur.size,cur.kind =  terra.pointertolightuserdata(content), size, "file"
    end
end

local function getinternalizedfile(path)
    local cur = internalizedfiles
    for segment in fileparts(path) do
        if cur.children and cur.children[segment] then
            cur = cur.children[segment]
        else return end
    end
    return cur
end

local clangresourcedirectory = "$CLANG_RESOURCE$"
local function headerprovider(path)
    if path:sub(1,#clangresourcedirectory) == clangresourcedirectory then
        return getinternalizedfile(path)
    end
end



function terra.includecstring(code,cargs,target)
    local args = terra.newlist {"-O3","-Wno-deprecated","-resource-dir",clangresourcedirectory}
    target = target or terra.nativetarget

    if (target == terra.nativetarget and ffi.os == "Linux") or (target.Triple and target.Triple:match("linux")) then
        args:insert("-internal-isystem")
        args:insert(clangresourcedirectory.."/include")
    end
    
    if cargs then
        args:insertall(cargs)
    end
    for p in terra.includepath:gmatch("([^;]+);?") do
        args:insert("-I")
        args:insert(p)
    end
    assert(terra.istarget(target),"expected a target or nil to specify the native target")
    local result = terra.registercfile(target,code,args,headerprovider)
    local general,tagged,errors,macros = result.general,result.tagged,result.errors,result.macros
    local mt = { __index = includetableindex, errors = result.errors }
    local function addtogeneral(tbl)
        for k,v in pairs(tbl) do
            if not general[k] then
                general[k] = v
            end
        end
    end
    addtogeneral(tagged)
    addtogeneral(macros)
    setmetatable(general,mt)
    setmetatable(tagged,mt)
    return general,tagged,macros
end
function terra.includec(fname,cargs,target)
    return terra.includecstring("#include \""..fname.."\"\n",cargs,target)
end


-- GLOBAL MACROS
terra.sizeof = terra.internalmacro(
function(diag,tree,typ)
    return newobject(tree,T.sizeof,typ:astype())
end,
function (terratype,...)
    terratype:complete()
    return terra.llvmsizeof(terra.jitcompilationunit,terratype)
end
)
_G["sizeof"] = terra.sizeof
_G["vector"] = terra.internalmacro(
function(diag,tree,...)
    if not diag then
        error("nil first argument in vector constructor")
    end
    if not tree then
        error("nil second argument in vector constructor")
    end
    local exps = terra.newlist({...}):map(function(x) return x.tree end)
    return newobject(tree,T.vectorconstructor,nil,exps)
end,
terra.types.vector
)
_G["vectorof"] = terra.internalmacro(function(diag,tree,typ,...)
    local exps = terra.newlist({...}):map(function(x) return x.tree end)
    return newobject(tree,T.vectorconstructor,typ:astype(),exps)
end)
_G["array"] = terra.internalmacro(function(diag,tree,...)
    local exps = terra.newlist({...}):map(function(x) return x.tree end)
    return newobject(tree,T.arrayconstructor,nil,exps)
end)
_G["arrayof"] = terra.internalmacro(function(diag,tree,typ,...)
    local exps = terra.newlist({...}):map(function(x) return x.tree end)
    return newobject(tree,T.arrayconstructor,typ:astype(),exps)
end)

local function createunpacks(tupleonly)
    local function unpackterra(diag,tree,obj,from,to)
        local typ = obj:gettype()
        if not obj or not typ:isstruct() or (tupleonly and typ.convertible ~= "tuple") then
            return obj
        end
        if not obj:islvalue() then diag:reporterror("expected an lvalue") end
        local result = terralib.newlist()
        local entries = typ:getentries()
        from = from and tonumber(from:asvalue()) or 1
        to = to and tonumber(to:asvalue()) or #entries
        for i = from,to do 
            local e= entries[i]
            if e.field then
                local ident = newobject(tree,type(e.field) == "string" and T.namedident or T.symbolident,e.field)
                result:insert(newobject(tree,T.selectu,obj.tree,ident))
            end
        end
        return result
    end
    local function unpacklua(cdata,from,to)
        local t = type(cdata) == "cdata" and terra.typeof(cdata)
        if not t or not t:isstruct() or (tupleonly and t.convertible ~= "tuple") then 
          return cdata
        end
        local results = terralib.newlist()
        local entries = t:getentries()
        for i = tonumber(from) or 1,tonumber(to) or #entries do
            local e = entries[i]
            if e.field then
                local nm = terra.issymbol(e.field) and e.field:tocname() or e.field
                results:insert(cdata[nm])
            end
        end
        return unpack(results)
    end
    return unpackterra,unpacklua
end
terra.unpackstruct = terra.internalmacro(createunpacks(false))
terra.unpacktuple = terra.internalmacro(createunpacks(true))

_G["unpackstruct"] = terra.unpackstruct
_G["unpacktuple"] = terra.unpacktuple
_G["tuple"] = terra.types.tuple
_G["global"] = terra.global

terra.select = terra.internalmacro(function(diag,tree,guard,a,b)
    return newobject(tree,T.operator,"select", List { guard.tree, a.tree, b.tree })
end)
terra.debuginfo = terra.internalmacro(function(diag,tree,filename,linenumber)
    local customfilename,customlinenumber = tostring(filename:asvalue()), tonumber(linenumber:asvalue())
    return newobject(tree,T.debuginfo,customfilename,customlinenumber)
end)

local function createattributetable(q)
    local attr = q:asvalue()
    if type(attr) ~= "table" then
        error("attributes must be a table")
    end
    return T.attr(attr.nontemporal and true or false, 
                  type(attr.align) == "number" and attr.align or nil,
                  attr.isvolatile and true or false)
end

terra.attrload = terra.internalmacro( function(diag,tree,addr,attr)
    if not addr or not attr then
        error("attrload requires two arguments")
    end
    return newobject(tree,T.attrload,addr.tree,createattributetable(attr))
end)

terra.attrstore = terra.internalmacro( function(diag,tree,addr,value,attr)
    if not addr or not value or not attr then
        error("attrstore requires three arguments")
    end
    return newobject(tree,T.attrstore,addr.tree,value.tree,createattributetable(attr))
end)


-- END GLOBAL MACROS

-- DEBUG

function terra.func:__tostring()
    return "<terra function>"
end

local function printpretty(breaklines,toptree,returntype,start,...)
    breaklines = breaklines == nil or breaklines
    local buffer = terralib.newlist() -- list of strings that concat together into the pretty output
    local env = terra.newenvironment({})
    local indentstack = terralib.newlist{ 0 } -- the depth of each indent level
    
    local currentlinelength = 0
    local function enterblock()
        indentstack:insert(indentstack[#indentstack] + 4)
    end
    local function enterindenttocurrentline()
        indentstack:insert(currentlinelength)
    end
    local function leaveblock()
        indentstack:remove()
    end
    local function emit(fmt,...)
        local function toformat(x)
            if type(x) ~= "number" and type(x) ~= "string" then
                return tostring(x) 
            else
                return x
            end
        end
        local strs = terra.newlist({...}):map(toformat)
        local r = fmt:format(unpack(strs))
        currentlinelength = currentlinelength + #r
        buffer:insert(r)
    end
    local function pad(str,len)
        if #str > len then return str:sub(-len)
        else return str..(" "):rep(len - #str) end
    end
    local function differentlocation(a,b)
        return (a.linenumber ~= b.linenumber or a.filename ~= b.filename)
    end 
    local lastanchor = { linenumber = "", filename = "" }
    local function begin(anchor,...)
        local fname = differentlocation(lastanchor,anchor) and (anchor.filename..":"..anchor.linenumber..": ")
                                                           or ""
        emit("%s",pad(fname,24))
        currentlinelength = 0
        emit((" "):rep(indentstack[#indentstack]))
        emit(...)
        lastanchor = anchor
    end

    local function emitList(lst,begin,sep,finish,fn)
        emit(begin)
        for i,k in ipairs(lst) do
            fn(k,i)
            if i ~= #lst then
                emit(sep)
            end
        end
        emit(finish)
    end

    local function emitType(t)
        emit("%s",t)
    end

    local function UniqueName(name,key)
        assert(name) assert(key)
        local lenv = env:localenv()
        local assignedname = lenv[key]
        --if we haven't seen this key in this scope yet, assign a name for this key, favoring the non-mangled name
        if not assignedname then
            local basename,i = name,1
            while lenv[name] do
                name,i = basename.."$"..tostring(i),i+1
            end
            lenv[name],lenv[key],assignedname = true,name,name
        end
        return assignedname
    end
    local function emitIdent(name,sym)
        assert(name) assert(terra.issymbol(sym))
        emit("%s",UniqueName(name,sym))
    end
    local function IdentToString(ident)
        return tostring(ident.value)
    end
    local function emitParam(p)
        assert(T.allocvar:isclassof(p) or T.concreteparam:isclassof(p))
        emitIdent(p.name,p.symbol)
        if p.type then 
            emit(" : %s",p.type)
        end
    end
    local emitStmt, emitExp,emitParamList,emitLetIn
    local function emitStmtList(lst) --nested Blocks (e.g. from quotes need "do" appended)
        for i,ss in ipairs(lst) do
            if ss:is "block" and not (#ss.statements == 1 and ss.statements[1].kind == "repeatstat") then
                begin(ss,"do\n")
                emitStmt(ss)
                begin(ss,"end\n")
            else
                emitStmt(ss)
            end
        end
    end
    local function emitAttr(a)
        emit("{ nontemporal = %s, align = %s, isvolatile = %s }",a.nontemporal,a.align or "native",a.isvolatile)
    end
    function emitStmt(s)
        if s:is "block" then
            enterblock()
            env:enterblock()
            emitStmtList(s.statements)
            env:leaveblock()
            leaveblock()
        elseif s:is "letin" then
            emitStmtList(s.statements)
            emitStmtList(s.expressions)
        elseif s:is "treelist" then
            emitStmtList(s.trees)
        elseif s:is "apply" then
            begin(s,"%s = ",UniqueName("r",s))
            emitExp(s)
            emit("\n")
        elseif s:is "returnstat" then
            begin(s,"return ")
            emitExp(s.expression)
            emit("\n")
        elseif s:is "label" then
            begin(s,"::%s::\n",IdentToString(s.value))
        elseif s:is "gotostat" then
            begin(s,"goto %s (%s)\n",IdentToString(s.label),s.deferred or "")
        elseif s:is "breakstat" then
            begin(s,"break (%s)\n",s.deferred or "")
        elseif s:is "whilestat" then
            begin(s,"while ")
            emitExp(s.condition)
            emit(" do\n")
            emitStmt(s.body)
            begin(s,"end\n")
        elseif s:is "repeatstat" then
            begin(s,"repeat\n")
            enterblock()
            emitStmtList(s.statements)
            leaveblock()
            begin(s.condition,"until ")
            emitExp(s.condition)
            emit("\n")
        elseif s:is "fornum"or s:is "fornumu" then
            begin(s,"for ")
            emitParam(s.variable)
            emit(" = ")
            emitExp(s.initial) emit(",") emitExp(s.limit) 
            if s.step then emit(",") emitExp(s.step) end
            emit(" do\n")
            emitStmt(s.body)
            begin(s,"end\n")
        elseif s:is "forlist" then
            begin(s,"for ")
            emitList(s.variables,"",", ","",emitParam)
            emit(" in ")
            emitExp(s.iterator)
            emit(" do\n")
            emitStmt(s.body)
            begin(s,"end\n")
        elseif s:is "ifstat" then
            for i,b in ipairs(s.branches) do
                if i == 1 then
                    begin(b,"if ")
                else
                    begin(b,"elseif ")
                end
                emitExp(b.condition)
                emit(" then\n")
                emitStmt(b.body)
            end
            if s.orelse then
                begin(s.orelse,"else\n")
                emitStmt(s.orelse)
            end
            begin(s,"end\n")
        elseif s:is "defvar" then
            begin(s,"var ")
            emitList(s.variables,"",", ","",emitParam)
            if s.hasinit then
                emit(" = ")
                emitParamList(s.initializers)
            end
            emit("\n")
        elseif s:is "assignment" then
            begin(s,"")
            emitParamList(s.lhs)
            emit(" = ")
            emitParamList(s.rhs)
            emit("\n")
        elseif s:is "defer" then
            begin(s,"defer ")
            emitExp(s.expression)
            emit("\n")
        else
            begin(s,"")
            emitExp(s)
            emit("\n")
        end
    end
    
    local function makeprectable(...)
        local lst = {...}
        local sz = #lst
        local tbl = {}
        for i = 1,#lst,2 do
            tbl[lst[i]] = lst[i+1]
        end
        return tbl
    end

    local prectable = makeprectable(
     "+",7,"-",7,"*",8,"/",8,"%",8,
     "^",11,"..",6,"<<",4,">>",4,
     "==",3,"<",3,"<=",3,
     "~=",3,">",3,">=",3,
     "and",2,"or",1,
     "@",9,"&",9,"not",9,"select",12)
    
    local function getprec(e)
        if e:is "operator" then
            if "-" == e.operator and #e.operands == 1 then return 9 --unary minus case
            else return prectable[e.operator] end
        else
            return 12
        end
    end
    local function doparens(ref,e,isrhs)
        local pr, pe = getprec(ref), getprec(e)
        if pr > pe or (isrhs and pr == pe) then
            emit("(")
            emitExp(e)
            emit(")")
        else
            emitExp(e)
        end
    end

    function emitExp(e)
        if breaklines and differentlocation(lastanchor,e)then
            local ll = currentlinelength
            emit("\n")
            begin(e,"")
            emit((" "):rep(ll - currentlinelength))
            lastanchor = e
        end
        if e:is "var" then
            emitIdent(e.name,e.symbol)
        elseif e:is "globalvar" then
            emitIdent(e.name,e.value.symbol)
        elseif e:is "allocvar" then
            emit("var ")
            emitParam(e)
        elseif e:is "setter" then
            emit("<setter>")
        elseif e:is "operator" then
            local op = e.operator
            local function emitOperand(o,isrhs)
                doparens(e,o,isrhs)
            end
            if #e.operands == 1 then
                emit(op)
                emitOperand(e.operands[1])
            elseif #e.operands == 2 then
                emitOperand(e.operands[1])
                emit(" %s ",op)
                emitOperand(e.operands[2],true)
            elseif op == "select" then
                emit("terralib.select")
                emitList(e.operands,"(",", ",")",emitExp)
            else
                emit("<??operator:"..op.."??>")
            end
        elseif e:is "index" then
            doparens(e,e.value)
            emit("[")
            emitExp(e.index)
            emit("]")
        elseif e:is "literal" then
            if e.type:ispointer() and e.type.type:isfunction() then
                emit(e.value.name)
            elseif e.type:isintegral() then
                emit(e.stringvalue or "<int>")
            elseif type(e.value) == "string" then
                emit("%q",e.value)
            else
                emit("%s",tostring(e.value))
            end
        elseif e:is "luafunction" then
            emit("<lua %s>",tostring(e.fptr))
        elseif e:is "cast" or e:is "structcast" then
            emit("[")
            emitType(e.to or e.type)
            emit("](")
            emitExp(e.expression)
            emit(")")
        elseif e:is "sizeof" then
            emit("sizeof(%s)",e.oftype)
        elseif e:is "apply" then
            doparens(e,e.value)
            emit("(")
            emitParamList(e.arguments)
            emit(")")
        elseif e:is "selectu" or e:is "select" then
            doparens(e,e.value)
            emit(".")
            emit("%s",e.fieldname or IdentToString(e.field))
        elseif e:is "vectorconstructor" then
            emit("vector(")
            emitParamList(e.expressions)
            emit(")")
        elseif e:is "arrayconstructor" then
            emit("array(")
            emitParamList(e.expressions)
            emit(")")
        elseif e:is "constructor" then
            local success,keys = pcall(function() return e.type:getlayout().entries:map(function(e) return tostring(e.key) end) end)
            if not success then emit("<layouttypeerror> = ") 
            else emitList(keys,"",", "," = ",emit) end
            emitParamList(e.expressions)
        elseif e:is "constructoru" then
            emit("{")
            local function emitField(r)
                if r.type == "recfield" then
                    emit("%s = ",IdentToString(r.key))
                end
                emitExp(r.value)
            end
            emitList(e.records,"",", ","",emitField)
            emit("}")
        elseif e:is "constant" then
            if e.type:isprimitive() then
                emit("%s",tostring(tonumber(e.value.object)))
            else
                emit("<constant:"..tostring(e.type)..">")
            end
        elseif e:is "letin" then
            emitLetIn(e)
        elseif e:is "treelist" then
            emitList(e.trees,"{",",","}",emitExp)
        elseif e:is "attrload" then
            emit("attrload(")
            emitExp(e.address)
            emit(", ")
            emitAttr(e.attrs)
            emit(")")
        elseif e:is "attrstore" then
            emit("attrstore(")
            emitExp(e.address)
            emit(", ")
            emitExp(e.value)
            emit(", ")
            emitAttr(e.attrs)
            emit(")")
        elseif e:is "luaobject" then
            if terra.types.istype(e.value) then
                emit("[%s]",e.value)
            elseif terra.ismacro(e.value) then
                emit("<macro>")
            elseif terra.isfunction(e.value) then
                emit("%s",e.value.name or e.value:getdefinitions()[1].name or "<anonfunction>")
            else
                emit("<lua value: %s>",tostring(e.value))
            end
        elseif e:is "method" then
             doparens(e,e.value)
             emit(":%s",IdentToString(e.name))
             emit("(")
             emitParamList(e.arguments)
             emit(")")
        elseif e:is "typedexpression" then
            emitExp(e.expression)
        elseif e:is "debuginfo" then
            emit("debuginfo(%q,%d)",e.customfilename,e.customlinenumber)
        elseif e:is "inlineasm" then
            emit("inlineasm(")
            emitType(e.type)
            emit(",%s,%s,%s,",e.asm,tostring(volatile),e.constraints)
            emitParams(e.arguments)
            emit(")")
        else
            emit("<??"..e.kind.."??>")
            error("??"..tostring(e.kind))
        end
    end
    function emitParamList(pl)
        emitList(pl,"",", ","",emitExp)
    end
    function emitLetIn(pl)
        if pl.hasstatements then
            enterindenttocurrentline()
            emit("let\n")
            enterblock()
            emitStmtList(pl.statements)
            leaveblock()
            begin(pl,"in\n")
            enterblock()
            begin(pl,"")
        end
        emitList(pl.expressions,"",", ","",emitExp)
        if pl.hasstatements then
            leaveblock()
            emit("\n")
            begin(pl,"end")
            leaveblock()
        end
    end    
    begin(toptree,start,...)
    if T.functiondef:isclassof(toptree) or T.functiondefu:isclassof(toptree) then
        emit("terra")
        emitList(toptree.parameters,"(",",",") ",emitParam)
        if returntype then
            emit(": ")
            emitType(returntype)
        end
        emit("\n")
        emitStmt(toptree.body)
        begin(toptree,"end\n")
    else
        emitExp(toptree)
        emit("\n")
    end
    io.write(buffer:concat())
end

function terra.func:printpretty(printcompiled,breaklines)
    printcompiled = (printcompiled == nil) or printcompiled
    for i,v in ipairs(self.definitions) do
        v:printpretty(printcompiled,breaklines)
    end
end

function terra.funcdefinition:printpretty(printcompiled,breaklines)
    printcompiled = (printcompiled == nil) or printcompiled
    if self.isextern then
        io.write(("%s = <extern : %s>\n"):format(self.name,self.type))
        return
    end
    if printcompiled then
        if self.state ~= "error" then self:gettype() end
        return printpretty(breaklines,self.typedtree,self.type.returntype,"%s = ",self.name)
    else
        return printpretty(breaklines,self.untypedtree,self.returntype,"%s = ",self.name)
    end
end
function terra.quote:printpretty(breaklines)
    printpretty(breaklines,self.tree,nil,"")
end


-- END DEBUG
local allowedfilekinds = { object = true, executable = true, bitcode = true, llvmir = true, sharedlibrary = true, asm = true }
local mustbefile = { sharedlibrary = true, executable = true }
function compilationunit:saveobj(filename,filekind,arguments)
    if filekind ~= nil and type(filekind) ~= "string" then
        --filekind is missing, shift arguments to the right
        filekind,arguments = nil,filekind
    end
    if filekind == nil and filename ~= nil then
        --infer filekind from string
        if filename:match("%.o$") then
            filekind = "object"
        elseif filename:match("%.bc$") then
            filekind = "bitcode"
        elseif filename:match("%.ll$") then
            filekind = "llvmir"
        elseif filename:match("%.so$") or filename:match("%.dylib$") or filename:match("%.dll$") then
            filekind = "sharedlibrary"
        elseif filename:match("%.s") then
            filekind = "asm"
        else
            filekind = "executable"
        end
    end
    if not allowedfilekinds[filekind] then
        error("unknown output format type: " .. tostring(filekind))
    end
    if filename == nil and mustbefile[filekind] then
        error(filekind .. " must be written to a file")
    end
    return terra.saveobjimpl(filename,filekind,self,arguments or {})
end

function terra.saveobj(filename,filekind,env,arguments,target)
    if type(filekind) ~= "string" then
        filekind,env,arguments,target = nil,filekind,env,arguments
    end
    local cu = terra.newcompilationunit(target or terra.nativetarget,false)
    for k,v in pairs(env) do
        if terra.isfunction(v) then
            local definitions = v:getdefinitions()
            if #definitions ~= 1 then
                error("cannot create a C function from an overloaded terra function, "..k)
            end
            v = definitions[1]
        elseif not terra.isglobalvar(v) then error("expected terra globals or functions but found "..terra.type(v)) end
        cu:addvalue(k,v)
    end
    local r = cu:saveobj(filename,filekind,arguments)
    cu:free()
    return r
end

-- configure path variables
terra.cudahome = os.getenv("CUDA_HOME") or (ffi.os == "Windows" and os.getenv("CUDA_PATH")) or "/usr/local/cuda"

if ffi.os == "Windows" then
    -- this is the reason we can't have nice things
    terra.vchome = os.getenv("VCINSTALLDIR")
    if not terra.vchome then --vsvarsall.bat has not been run guess defaults
        local ct = os.getenv("VS120COMNTOOLS")
        if ct then
            terra.vchome = ct..[[..\..\VC\]]
        else
            terra.vchome = [[C:\Program Files (x86)\Microsoft Visual Studio 12.0\VC\]]
        end
    else
        --assume vsvarsall.bat was run and get lib/path
        terra.vcpath = os.getenv("Path")
        terra.vclib = os.getenv("LIB")
    end
    function terra.getvclinker() --get the linker, and guess the needed environment variables for Windows if they are not set ...
        local linker = terra.vchome..[[BIN\x86_amd64\link.exe]]
        local vclib = terra.vclib or string.gsub([[%LIB\amd64;%ATLMFC\LIB\amd64;C:\Program Files (x86)\Windows Kits\8.1\lib\winv6.3\um\x64;]],"%%",terra.vchome)
        local vcpath = terra.vcpath or (os.getenv("Path") or "")..";"..terra.vchome..[[BIN;]]
        vclib,vcpath = "LIB="..vclib,"Path="..vcpath
        return linker,vclib,vcpath
    end
end


-- path to terra install, normally this is figured out based on the location of Terra shared library or binary
local defaultterrahome = ffi.os == "Windows" and "C:\\Program Files\\terra" or "/usr/local"
terra.terrahome = os.getenv("TERRA_HOME") or terra.terrahome or defaultterrahome
local terradefaultpath =  ffi.os == "Windows" and ";.\\?.t;"..terra.terrahome.."\\include\\?.t;"
                          or ";./?.t;"..terra.terrahome.."/share/terra/?.t;"

package.terrapath = (os.getenv("TERRA_PATH") or ";;"):gsub(";;",terradefaultpath)

local function terraloader(name)
    local fname = name:gsub("%.","/")
    local file = nil
    local loaderr = ""
    for template in package.terrapath:gmatch("([^;]+);?") do
        local fpath = template:gsub("%?",fname)
        local handle = io.open(fpath,"r")
        if handle then
            file = fpath
            handle:close()
            break
        end
        loaderr = loaderr .. "\n\tno file '"..fpath.."'"
    end
    local function check(fn,err) return fn or error(string.format("error loading terra module %s from file %s:\n\t%s",name,file,err)) end
    if file then return check(terra.loadfile(file)) end
    -- if we didn't find the file on the real file system, see if it is included in the binary itself
    file = ("/?.t"):gsub("%?",fname)
    local internal = getinternalizedfile(file)
    if internal and internal.kind == "file" then
        local str,done = ffi.string(ffi.cast("const char *",internal.contents)),false
        local fn,err = terra.load(function()
            if not done then
                done = true
                return str
            end
        end,file)
        return check(fn,err)
    else
        loaderr = loaderr .. "\n\tno internal file '"..file.."'"
    end
    return loaderr
end
table.insert(package.loaders,terraloader)

function terra.makeenv(env,defined,g)
    local mt = { __index = function(self,idx)
        if defined[idx] then return nil -- local variable was defined and was nil, the search ends here
        elseif getmetatable(g) == Strict then return rawget(g,idx) else return g[idx] end
    end }
    return setmetatable(env,mt)
end

function terra.new(terratype,...)
    terratype:complete()
    local typ = terratype:cstring()
    return ffi.new(typ,...)
end
function terra.offsetof(terratype,field)
    terratype:complete()
    local typ = terratype:cstring()
    if terra.issymbol(field) then
        field = "__symbol"..field.id
    end
    return ffi.offsetof(typ,field)
end

function terra.cast(terratype,obj)
    terratype:complete()
    local ctyp = terratype:cstring()
    return ffi.cast(ctyp,obj)
end

terra.constantobj = {}
terra.constantobj.__index = terra.constantobj

--c.object is the cdata value for this object
--string constants are handled specially since they should be treated as objects and not pointers
--in this case c.object is a string rather than a cdata object
--c.type is the terra type


function terra.isconstant(obj)
    return getmetatable(obj) == terra.constantobj
end

function terra.constant(a0,a1)
    if terra.types.istype(a0) then
        local c = setmetatable({ type = a0, object = a1 },terra.constantobj)
        --special handling for string literals
        if type(c.object) == "string" and c.type == terra.types.rawstring then
            c.stringvalue = c.object --save string type for special handling in compiler
        end

        --if the  object is not already cdata, we need to convert it
        if  type(c.object) ~= "cdata" or terra.typeof(c.object) ~= c.type then
            local obj = c.object
            c.object = terra.cast(c.type,obj)
            c.origobject = type(obj) == "cdata" and obj --conversion from obj -> &obj
                                                        --need to retain reference to obj or it can be GC'd
        end
        return c
    else
        --try to infer the type, and if successful build the constant
        local init,typ = a0,nil
        if terra.isconstant(init) then
            return init --already a constant
        elseif type(init) == "cdata" then
            typ = terra.typeof(init)
        elseif type(init) == "number" then
            typ = (terra.isintegral(init) and terra.types.int) or terra.types.double
        elseif type(init) == "boolean" then
            typ = terra.types.bool
        elseif type(init) == "string" then
            typ = terra.types.rawstring
        else
            error("constant constructor requires explicit type for objects of type "..type(init))
        end
        return terra.constant(typ,init)
    end
end
_G["constant"] = terra.constant

-- equivalent to ffi.typeof, takes a cdata object and returns associated terra type object
function terra.typeof(obj)
    if type(obj) ~= "cdata" then
        error("cannot get the type of a non cdata object")
    end
    return terra.types.ctypetoterra[tonumber(ffi.typeof(obj))]
end

--equivalent to Lua's type function, but knows about concepts in Terra to improve error reporting
function terra.type(t)
    if terra.isfunction(t) then return "terrafunction"
    elseif terra.types.istype(t) then return "terratype"
    elseif terra.ismacro(t) then return "terramacro"
    elseif terra.isglobalvar(t) then return "terraglobalvariable"
    elseif terra.isquote(t) then return "terraquote"
    elseif terra.istree(t) then return "terratree"
    elseif terra.islist(t) then return "list"
    elseif terra.issymbol(t) then return "terrasymbol"
    elseif terra.isfunctiondefinition(t) then return "terrafunctiondefinition"
    elseif terra.isconstant(t) then return "terraconstant"
    else return type(t) end
end

function terra.linklibrary(filename)
    assert(not filename:match(".bc$"), "linklibrary no longer supports llvm bitcode, use terralib.linkllvm instead.")
    terra.linklibraryimpl(filename)
end
function terra.linkllvm(filename,target)
    target = target or terra.nativetarget
    assert(terra.istarget(target),"expected a target or nil to specify native target")
    terra.linkllvmimpl(target.llvm_target,filename)
    return { extern = function(self,name,typ) return terra.externfunction(name,typ) end }
end

terra.languageextension = {
    tokentype = {}; --metatable for tokentype objects
    tokenkindtotoken = {}; --map from token's kind id (terra.kind.name), to the singleton table (terra.languageextension.name) 
}

function terra.importlanguage(languages,entrypoints,langstring)
    local success,lang = xpcall(function() return require(langstring) end,function(err) return debug.traceback(err,2) end)
    if not success then error(lang,0) end
    if not lang or type(lang) ~= "table" then error("expected a table to define language") end
    lang.name = lang.name or "anonymous"
    local function haslist(field,typ)
        if not lang[field] then 
            error(field .. " expected to be list of "..typ)
        end
        for i,k in ipairs(lang[field]) do
            if type(k) ~= typ then
                error(field .. " expected to be list of "..typ.." but found "..type(k))
            end
        end
    end
    haslist("keywords","string")
    haslist("entrypoints","string")
    
    for i,e in ipairs(lang.entrypoints) do
        if entrypoints[e] then
            error(("language '%s' uses entrypoint '%s' already defined by language '%s'"):format(lang.name,e,entrypoints[e].name),-1)
        end
        entrypoints[e] = lang
    end
    if not lang.keywordtable then
        lang.keywordtable = {} --keyword => true
        for i,k in ipairs(lang.keywords) do
            lang.keywordtable[k] = true
        end
        for i,k in ipairs(lang.entrypoints) do
            lang.keywordtable[k] = true
        end
    end
    table.insert(languages,lang)
end
function terra.unimportlanguages(languages,N,entrypoints)
    for i = 1,N do
        local lang = table.remove(languages)
        for i,e in ipairs(lang.entrypoints) do
            entrypoints[e] = nil
        end
    end
end

function terra.languageextension.tokentype:__tostring()
    return self.name
end

do
    local special = { "name", "string", "number", "eof", "default" }
    --note: default is not a tokentype but can be used in libraries to match
    --a token that is not another type
    for i,k in ipairs(special) do
        local name = "<" .. k .. ">"
        local tbl = setmetatable({
            name = name }, terra.languageextension.tokentype )
        terra.languageextension[k] = tbl
        terra.languageextension.tokenkindtotoken[name] = tbl
    end
end

function terra.runlanguage(lang,cur,lookahead,next,embeddedcode,source,isstatement,islocal)
    local lex = {}
    
    lex.name = terra.languageextension.name
    lex.string = terra.languageextension.string
    lex.number = terra.languageextension.number
    lex.eof = terra.languageextension.eof
    lex.default = terra.languageextension.default

    lex._references = terra.newlist()
    lex.source = source

    local function maketoken(tok)
        local specialtoken = terra.languageextension.tokenkindtotoken[tok.type]
        if specialtoken then
            tok.type = specialtoken
        end
        if type(tok.value) == "userdata" then -- 64-bit number in pointer
            tok.value = terra.cast(terra.types.pointer(tok.valuetype),tok.value)[0]
        end
        return tok
    end
    function lex:cur()
        self._cur = self._cur or maketoken(cur())
        return self._cur
    end
    function lex:lookahead()
        self._lookahead = self._lookahead or maketoken(lookahead())
        return self._lookahead
    end
    function lex:next()
        local v = self:cur()
        self._cur,self._lookahead = nil,nil
        next()
        return v
    end
    local function doembeddedcode(self,isterra,isexp)
        self._cur,self._lookahead = nil,nil --parsing an expression invalidates our lua representations 
        local expr = embeddedcode(isterra,isexp)
        return function(env)
            local oldenv = getfenv(expr)
            setfenv(expr,env)
            local function passandfree(...)
                setfenv(expr,oldenv)
                return ...
            end
            return passandfree(expr())
        end
    end
    function lex:luaexpr() return doembeddedcode(self,false,true) end
    function lex:luastats() return doembeddedcode(self,false,false) end
    function lex:terraexpr() return doembeddedcode(self,true,true) end
    function lex:terrastats() return doembeddedcode(self,true,false) end

    function lex:ref(name)
        if type(name) ~= "string" then
            error("references must be identifiers")
        end
        self._references:insert(name)
    end

    function lex:typetostring(name)
        return name
    end
    
    function lex:nextif(typ)
        if self:cur().type == typ then
            return self:next()
        else return false end
    end
    function lex:expect(typ)
        local n = self:nextif(typ)
        if not n then
            self:errorexpected(tostring(typ))
        end
        return n
    end
    function lex:matches(typ)
        return self:cur().type == typ
    end
    function lex:lookaheadmatches(typ)
        return self:lookahead().type == typ
    end
    function lex:error(msg)
        error(msg,0) --,0 suppresses the addition of line number information, which we do not want here since
                     --this is a user-caused errors
    end
    function lex:errorexpected(what)
        self:error(what.." expected")
    end
    function lex:expectmatch(typ,openingtokentype,linenumber)
       local n = self:nextif(typ)
        if not n then
            if self:cur().linenumber == linenumber then
                lex:errorexpected(tostring(typ))
            else
                lex:error(string.format("%s expected (to close %s at line %d)",tostring(typ),tostring(openingtokentype),linenumber))
            end
        end
        return n
    end

    local constructor,names
    if isstatement and islocal and lang.localstatement then
        constructor,names = lang:localstatement(lex)
    elseif isstatement and not islocal and lang.statement then
        constructor,names = lang:statement(lex)
    elseif not islocal and lang.expression then
        constructor = lang:expression(lex)
    else
        lex:error("unexpected token")
    end
    
    if not constructor or type(constructor) ~= "function" then
        error("expected language to return a construction function")
    end

    local function isidentifier(str)
        local b,e = string.find(str,"[%a_][%a%d_]*")
        return b == 1 and e == string.len(str)
    end

    --fixup names    

    if not names then 
        names = {}
    end

    if type(names) ~= "table" then
        error("names returned from constructor must be a table")
    end

    if islocal and #names == 0 then
        error("local statements must define at least one name")
    end

    for i = 1,#names do
        if type(names[i]) ~= "table" then
            names[i] = { names[i] }
        end
        local name = names[i]
        if #name == 0 then
            error("name must contain at least one element")
        end
        for i,c in ipairs(name) do
            if type(c) ~= "string" or not isidentifier(c) then
                error("name component must be an identifier")
            end
            if islocal and i > 1 then
                error("local names must have exactly one element")
            end
        end
    end

    return constructor,names,lex._references
end

_G["operator"] = terra.internalmacro(function(diag,anchor,op,...)
        local tbl = {
            __sub = "-";
            __add = "+";
            __mul = "*";
            __div = "/";
            __mod = "%";
            __lt = "<";
            __le = "<=";
            __gt = ">";
            __ge = ">=";
            __eq = "==";
            __ne = "~=";
            __and = "and";
            __or = "or";
            __not = "not";
            __xor = "^";
            __lshift = "<<";
            __rshift = ">>";
            __select = "select";
        }
    local opv = op:asvalue()
    opv = tbl[opv] or opv --operator can be __add or +
    local operands= List()
    for i = 1,select("#",...) do
        operands:insert(select(i,...).tree)
    end
    return newobject(anchor,T.operator,opv,operands)
end)
--called by tcompiler.cpp to convert userdata pointer to stacktrace function to the right type;
function terra.initdebugfns(traceback,backtrace,lookupsymbol,lookupline,disas)
    local P,FP = terra.types.pointer, terra.types.funcpointer
    local po = P(terra.types.opaque)
    local ppo = P(po)

    terra.SymbolInfo = terra.types.newstruct("SymbolInfo")
    terra.SymbolInfo.entries = { {"addr", ppo}, {"size", terra.types.uint64}, {"name",terra.types.rawstring}, {"namelength",terra.types.uint64} };
    terra.LineInfo = terra.types.newstruct("LineInfo")
    terra.LineInfo.entries = { {"name",terra.types.rawstring}, {"namelength",terra.types.uint64},{"linenum", terra.types.uint64}};

    terra.traceback = terra.cast(FP({po},{}),traceback)
    terra.backtrace = terra.cast(FP({ppo,terra.types.int,po,po},{terra.types.int}),backtrace)
    terra.lookupsymbol = terra.cast(FP({po,P(terra.SymbolInfo)},{terra.types.bool}),lookupsymbol)
    terra.lookupline   = terra.cast(FP({po,po,P(terra.LineInfo)},{terra.types.bool}),lookupline)
    terra.disas = terra.cast(FP({po,terra.types.uint64,terra.types.uint64},{}),disas)
end

_G["terralib"] = terra --terra code can't use "terra" because it is a keyword
--io.write("done\n")
