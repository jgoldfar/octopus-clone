/*
 Copyright (C) 2015 X. Andrade

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2, or (at your option)
 any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program; if not, write to the Free Software
 Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
 02110-1301, USA.

 $Id:$
*/

#include <stdio.h>
#include <config.h>
#include <fortran_types.h>
#include "string_f.h"
#include <string.h>

/* #define XML_FILE_DEBUG */

typedef struct {
  FILE * xml_file;
  fpos_t pos;
} tag_t;


static void seek_tag(FILE ** xml_file, const char * tag, int index, const int end_of_tag){
  fpos_t startpos;
  char * res;
  char buffer[1000];
  char endchar;

  fgetpos(*xml_file, &startpos);

  while(fgets(buffer, sizeof(buffer), *xml_file)){

#ifdef XML_FILE_DEBUG
    /*    printf("line: %s\n", buffer); */
#endif
    
    /* check for the tag */
    res = strstr(buffer, tag);

    /* the string was found */
    if(res != NULL) index--;

    if(index == -1){
    
#ifdef XML_FILE_DEBUG
      printf("Tag was found in line: %s", res);
#endif

      if(end_of_tag){
	/* find where the tag is closed */
	endchar = '>';
      } else {
	/* or where the list of attributes starts */
	endchar = ' ';
      }
    
      while(res[0] != endchar) res++;
    
      /* go back to the beginning of the line */
      fsetpos(*xml_file, &startpos);
      
      /* and move to the end of the tag */
      fseek(*xml_file, res - buffer + 1, SEEK_CUR);
    
      break;
    }

    fgetpos(*xml_file, &startpos);
  }
}

fint FC_FUNC_(xml_file_init, XML_FILE_INIT)(FILE ** xml_file, STR_F_TYPE fname STR_ARG1)
{

  char *fname_c;
  TO_C_STR1(fname, fname_c);

#ifdef XML_FILE_DEBUG
  printf("Opening file \"%s\": ", fname_c);
#endif

  *xml_file = fopen(fname_c, "r");

#ifdef XML_FILE_DEBUG
  if(*xml_file != NULL){ 
    printf("success\n");
  } else {
    printf("failed\n");
  }
#endif

  free(fname_c);

  if(*xml_file == NULL){
    return 1;
  } else {
    return 0;
  }

}

fint FC_FUNC_(xml_file_tag, XML_FILE_TAG)(FILE ** xml_file, STR_F_TYPE tagname_f, const fint * index, tag_t ** tag STR_ARG1)
{
  char *origtagname;
  char *tagname;
  
  TO_C_STR1(tagname_f, origtagname);

  tagname = (char *) malloc(strlen(origtagname) + 2);

  strcpy(tagname, "<");
  strcat(tagname, origtagname);  
 
#ifdef XML_FILE_DEBUG
  printf("Opened tag \"%s\" index %d.\n", origtagname, *index);
#endif

  free(origtagname);
  
  *tag = (tag_t *) malloc(sizeof(tag_t));

  (*tag)->xml_file = *xml_file;

  fseek(*xml_file, 0, SEEK_SET);
  seek_tag(xml_file, tagname, *index, 0);
  
  fgetpos(*xml_file, &(*tag)->pos);

  free(tagname);

  return 0;
}

void FC_FUNC_(xml_tag_end, XML_TAG_END)(tag_t ** tag)
{
  free(*tag);
}

fint FC_FUNC_(xml_tag_get_attribute_value, XML_TAG_GET_ATTRIBUTE_VALUE)(tag_t ** tag, STR_F_TYPE attname_f, fint * val STR_ARG1){
  char buffer[1000];
  char * res;
  char * attname;
  
  TO_C_STR1(attname_f, attname);
  
#ifdef XML_FILE_DEBUG
  printf("Reading attribute \"%s\".\n", attname);
#endif

  /* go to the start of the attribute list */
  fsetpos((*tag)->xml_file, &(*tag)->pos);
  fgets(buffer, sizeof(buffer), (*tag)->xml_file);

#ifdef XML_FILE_DEBUG
  /*  printf("line to parse: %s", buffer);*/
#endif

  res = strstr(buffer, attname);

  free(attname);
  
  if(res == NULL) return 1;

  res = strchr(res, '"') + 1;
  
#ifdef XML_FILE_DEBUG
  printf("line to parse: %s", res);
#endif

  sscanf(res, "%d", val);

#ifdef XML_FILE_DEBUG
  printf("got value: %d\n", *val);
#endif
  
  return 0;
}

fint FC_FUNC_(xml_file_read_integer_low, XML_FILE_READ_INTEGER_LOW)(FILE ** xml_file, STR_F_TYPE tag_f, fint * value STR_ARG1){
  char * tag;

  TO_C_STR1(tag_f, tag);

#ifdef XML_FILE_DEBUG
  printf("Reading tag \"%s>\" of type integer\n", tag);
#endif

  fseek(*xml_file, 0, SEEK_SET);
  seek_tag(xml_file, tag, 0, 1);

  fscanf(*xml_file, "%d", value);  

#ifdef XML_FILE_DEBUG
  printf("Got value: %d\n", *value);
#endif
			   
  free(tag);

  return 0;
}

fint FC_FUNC_(xml_file_read_double_low, XML_FILE_READ_DOUBLE_LOW)(FILE ** xml_file, STR_F_TYPE tag_f, double * value STR_ARG1){
  char * tag;

  TO_C_STR1(tag_f, tag);

#ifdef XML_FILE_DEBUG
  printf("Reading tag \"%s>\" of type double\n", tag);
#endif

  fseek(*xml_file, 0, SEEK_SET);
  seek_tag(xml_file, tag, 0, 1);

  fscanf(*xml_file, "%lf", value);  

#ifdef XML_FILE_DEBUG
  printf("Got value: %lf\n", *value);
#endif

  free(tag);

  return 0;
}

fint FC_FUNC_(xml_tag_get_tag_value_array_low, XML_TAG_GET_TAG_VALUE_ARRAY_LOW)
     (tag_t ** tag, STR_F_TYPE subtagname_f, const fint * size, double * val STR_ARG1){

  char *origsubtagname;
  char *subtagname;
  fint ii;
  
  TO_C_STR1(subtagname_f, origsubtagname);

  subtagname = (char *) malloc(strlen(origsubtagname) + 2);

  strcpy(subtagname, "<");
  strcat(subtagname, origsubtagname);  
 
#ifdef XML_FILE_DEBUG
  printf("Opened subtag \"%s\".\n", origsubtagname);
#endif

  free(origsubtagname);

  fsetpos((*tag)->xml_file, &(*tag)->pos);
  seek_tag(&(*tag)->xml_file, subtagname, 0, 1);

  for(ii = 0; ii < *size; ii++){
    fscanf((*tag)->xml_file, "%lf", val + ii);
  }
  
  free(subtagname);
  
  return 0;
}

void FC_FUNC_(xml_file_end, XML_FILE_END)(FILE ** xml_file)
{
  fclose(*xml_file);
}
