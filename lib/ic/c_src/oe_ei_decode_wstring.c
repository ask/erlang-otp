#include <ic.h>


/* Scratch function */
int oe_ei_decode_wstring(const char *buf, int *index, CORBA_wchar *p) {

  int length,error_code,type,tmp=0;
  char * tmp_space = NULL;


  if ((error_code = ei_get_type(buf, index, &type, &length)) < 0)
    return error_code;
  
  switch(type) {
    
  case ERL_LIST_EXT: /* A list */
  case ERL_NIL_EXT: /* An empty list */
    
    if (p) { /* Decoding part */

      if ((error_code = ei_decode_list_header(buf, index, &length)) < 0) 
	return error_code;
      
      if (length != 0) {
	for(tmp = 0; tmp < length; tmp++) 
	  if ((error_code = oe_ei_decode_wchar(buf, index, &(p[tmp]))) < 0)
	    return error_code;

	/* Read list tail also */
	if ((error_code = ei_decode_list_header(buf, index, &length)) < 0) 
	  return error_code;
      }
      
      p[tmp] = 0;   /* Wide NULL */
	
    } else { /* Allocation counting part */

      if ((error_code = ei_decode_list_header(buf, index, &length)) < 0) 
	return error_code;
      
      if (length != 0) {
	for(tmp = 0; tmp < length; tmp++) 
	  if ((error_code = oe_ei_decode_wchar(buf, index, 0)) < 0)
	    return error_code;

	/* Read list tail also */
	if ((error_code = ei_decode_list_header(buf, index, &length)) < 0) 
	  return error_code;
      }
    }
    
    break;

  case ERL_STRING_EXT: /* A string */

    if (p) { /* Decoding part */
      
      /* Allocate temporary string */
      tmp_space = (char*) malloc(length*(__OE_WCHARSZ__+1));

      if ((error_code = ei_decode_string(buf, index, tmp_space)) < 0)
	return error_code;
      
      /* Assign characters to wide characters */
      for(tmp = 0; tmp < length; tmp++)
	p[tmp] = tmp_space[tmp];
      
      p[tmp] = 0; /* Wide NULL */
      
      /* Free temporary string */
      CORBA_free(tmp_space);

    } else { /* Allocation counting part */
      
      if ((error_code = ei_decode_string(buf, index, 0)) < 0)
	return error_code;

    }
    break;

  default: /* Bad header */
    return -1; 
  }

  return 0;
}


