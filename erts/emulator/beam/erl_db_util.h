/* ``The contents of this file are subject to the Erlang Public License,
 * Version 1.1, (the "License"); you may not use this file except in
 * compliance with the License. You should have received a copy of the
 * Erlang Public License along with this software. If not, it can be
 * retrieved via the world wide web at http://www.erlang.org/.
 * 
 * Software distributed under the License is distributed on an "AS IS"
 * basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
 * the License for the specific language governing rights and limitations
 * under the License.
 * 
 * The Initial Developer of the Original Code is Ericsson Utvecklings AB.
 * Portions created by Ericsson are Copyright 1999, Ericsson Utvecklings
 * AB. All Rights Reserved.''
 * 
 *     $Id$
 */
#ifndef _DB_UTIL_H
#define _DB_UTIL_H

#include "global.h"
#include "erl_message.h"

/*#define HARDDEBUG 1*/

#ifdef DEBUG
/*
** DMC_DEBUG does NOT need DEBUG, but DEBUG needs DMC_DEBUG
*/
#define DMC_DEBUG 1
#endif

/*
** During development...
*/

typedef Eterm eTerm; /* Tagged erlang term */

/*
 * These values can be returned from the functions performing the 
 * BIF operation for different types of tables. When the
 * actual operations have been performed, the BIF function
 * checks for negative returns and issues BIF_ERRORS based 
 * upon these values.
 */
#define DB_ERROR_NONE      0     /* No error */
#define DB_ERROR_BADITEM  -1     /* The item was malformed ie no 
				   tuple or to small*/
#define DB_ERROR_BADTABLE -2     /* The Table is inconsisitent */
#define DB_ERROR_SYSRES   -3     /* Out of system resources */
#define DB_ERROR_BADKEY   -4     /* Returned if a key that should
				    exist does not. */
#define DB_ERROR_BADPARAM  -5     /* Returned if a specified slot does 
				     not exist (hash table only) or
				     the state parameter in db_match_object
				     is broken.*/
#define DB_ERROR_UNSPEC   -10    /* Unspecified error */


/*
 * A datatype for a database entry stored out of a process heap
 */
typedef struct db_term {
    Eterm *tpl;			/* Untagged pointer to the beginning of term*/
    ErlOffHeap off_heap;	/* Off heap data for term. */
    uint32 size;		/* Size of term in "words" */
    Eterm v[1];			/* Beginning of buffer for the terms */
} DbTerm;

/*
 * This structure contains data for all different types of database
 * tables. Note that these fields must match the same fields
 * in the table-type specific structures.
 * The reason it is placed here and not in db.h is that some table 
 * operations may be the same on different types of tables.
 */

typedef struct db_table_common {
    Eterm owner;              /* Pid of the creator */
    Eterm the_name;           /* an atom   */
    Eterm id;                 /* atom | integer | DB_USED | DB_NOTUSED */
    uint32 status;            /* bit masks defined  below */
    int slot;                 /* slot in db_tables */
    int keypos;               /* defaults to 1 */
    int nitems;               /* Total number of items */
} DbTableCommon;

/* XXX: as long as NIL is atom, don't use NIL as USED marker */
#define DB_NOTUSED	(_make_header(0,_TAG_HEADER_FLOAT))	/*XXX*/
#define DB_USED		(_make_header(3,_TAG_HEADER_FLOAT))	/*XXX*/

/* These are status bit patterns */
#define DB_NORMAL        (1 << 0)
#define DB_PRIVATE       (1 << 1)
#define DB_PROTECTED     (1 << 2)
#define DB_PUBLIC        (1 << 3)
#define DB_BAG           (1 << 4)
#define DB_SET           (1 << 5)
#define DB_LHASH         (1 << 6)
#define DB_FIXED         (1 << 7)
#define DB_DUPLICATE_BAG (1 << 8)
#define DB_ORDERED_SET   (1 << 9)


#define IS_HASH_TABLE(Status) (!!((Status) & \
				  (DB_BAG | DB_SET | DB_DUPLICATE_BAG)))
#define IS_TREE_TABLE(Status) (!!((Status) & \
				  DB_ORDERED_SET))
     /*TT*/

extern Eterm db_am_eot;		/* Atom '$end_of_table' */
extern Eterm db_big_buf[];

/* optimised version of copy_object (normal case? atomic object) */
#define COPY_OBJECT(obj, p, objp) \
   if (IS_CONST(obj)) { *(objp) = (obj); } \
   else { copy_object(obj, p, 0, objp, (Process*) 0); }

#define DB_READ  (DB_PROTECTED|DB_PUBLIC)
#define DB_WRITE DB_PUBLIC
#define DB_INFO  (DB_PROTECTED|DB_PUBLIC|DB_PRIVATE)

/*
 * Number of pre allocated bindings when db_do_match is called.
 */
#define DB_MATCH_NBIND 8  
/* Zero binding structure */
#define ZEROB(bind) do { int ii; for(ii = 0; ii < bind.size; ++ii) bind.ptr[ii] = THE_NON_VALUE; } while(0)

/* The actual binding structure */
typedef struct db_bindings {
    int size;
    Eterm *ptr;
    Uint *sz;
} DbBindings;

/* tb is an DbTableCommon and obj is an Eterm (tagged) */
#define TERM_GETKEY(tb, obj) db_getkey((tb)->common.keypos, (obj)) 

/* Function prototypes */
void db_initialize_util(void);
Eterm db_getkey(int keypos, Eterm obj);
int db_do_match(Eterm obj, Eterm pattern, DbBindings *bs);
Eterm add_counter(Eterm counter, Eterm incr);
int db_realloc_counter(void** bp, DbTerm *b, uint32 offset, uint32 sz, 
		       Eterm new_counter, int counterpos);
void db_free_term_data(DbTerm* p);
void* db_get_term(DbTerm* old, uint32 offset, Eterm obj);
int db_has_variable(Eterm obj);
int db_is_variable(Eterm obj);
int db_do_update_counter(Process *p, 
			 void *bp /* {Tree|Hash|XXX}DbTerm **bp */, 
			 Eterm *tpl, 
			 int counterpos,
			 int (*realloc_fun)(void *, uint32, Eterm, int),
			 Eterm incr,
			 Eterm *ret);
Eterm db_match_set_lint(Process *p, Eterm matchexpr, int flags);
Binary *db_match_set_compile(Process *p, Eterm matchexpr, 
			     int flags);

typedef struct match_prog {
    ErlHeapFragment *term_save; /* Only if needed, a list of message 
				    buffers for off heap copies 
				    (i.e. binaries)*/
    int single_variable;     /* ets:match needs to know this. */
    int num_bindings;        /* Size of heap */
    /* The following two are only filled in when match specs 
       are used for tracing */
    struct erl_heap_fragment *saved_program_buf;
    Eterm saved_program;
#ifdef DMC_DEBUG
    int stack_size;
#endif
    Eterm **stack;           /* Pointer to beginning of "large enough" 
				stack Actually points to area after eheap.*/
    Eterm *eheap;            /* Pointer to pre allocated erlang heap storage */
    Eterm *heap;             /* Pointer to beginnng of variable bindings 
				Actually points to area after text */
    Uint *labels;            /* Label offset's */
    Uint text[1];            /* Beginning of program */
} MatchProg;

#define DMC_ERR_STR_LEN 100

typedef enum { dmcWarning, dmcError} DMCErrorSeverity;

typedef struct dmc_error {
    char error_string[DMC_ERR_STR_LEN + 1]; /* printf format string
					       with %d for the variable
					       number (if applicable) */
    int variable;                           /* -1 if no variable is referenced
					       in error string */
    struct dmc_error *next;
    DMCErrorSeverity severity;              /* Error or warning */
} DMCError;

typedef struct dmc_err_info {
    unsigned int *var_trans; /* Translations of variable names, 
				initiated to NULL
				and free'd with sys_free if != NULL 
				after compilation */
    int num_trans;
    int error_added;         /* indicates if the error list contains
				any fatal errors (dmcError severity) */
    DMCError *first;         /* List of errors */
} DMCErrInfo;

/*
** Compilation flags
*/
#define DCOMP_BODY_RETURN       1
#define DCOMP_ALLOW_DBIF_BODY   2
#define DCOMP_MATCH_ARRAY       4 /* The parameter to the execution
				     will be an array, not a tuple. */


Binary *db_match_compile(Eterm *matchexpr, Eterm *guards,
			 Eterm *body, int num_matches, 
			 Uint32 flags, 
			 DMCErrInfo *err_info);
/* Returns newly allocated MatchProg binary with refc == 0*/
Eterm db_prog_match(Process *p, Binary *prog, Eterm term, int arity, 
		    Uint32 *return_flags /* Zeroed on enter */);
/* returns DB_ERROR_NONE if matches, 1 if not matches and some db error on 
   error. */
DMCErrInfo *db_new_dmc_err_info(void);
/* Returns allocated error info, where errors are collected for lint. */
Eterm db_format_dmc_err_info(Process *p, DMCErrInfo *ei);
/* Formats an error info structure into a list of tuples. */
void db_free_dmc_err_info(DMCErrInfo *ei);
/* Completely free's an error info structure, including all recorded 
   errors */

/*
** Convenience when compiling into Binary structures
*/
#define Binary2MatchProg(BP) ((MatchProg *) (BP)->orig_bytes)

/*
** Debugging 
*/
#ifdef HARDDEBUG
void db_check_tables(void); /* in db.c */
#define CHECK_TABLES() db_check_tables()
#else 
#define CHECK_TABLES()
#endif

#endif /* _DB_UTIL_H */
